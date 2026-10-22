create table public.mailing_subscribers (
 id uuid primary key default gen_random_uuid(),email text not null unique,first_name text not null default '',
 source text not null,consent_text text not null,consent_recorded_at timestamptz not null default now(),
 subscribed boolean not null default true,unsubscribed_at timestamptz,
 unsubscribe_token uuid not null default gen_random_uuid()
);
alter table public.mailing_subscribers enable row level security;
revoke all on public.mailing_subscribers from anon,authenticated;
grant select on public.mailing_subscribers to authenticated;
grant all on public.mailing_subscribers to service_role;
create policy "admin read subscribers" on public.mailing_subscribers for select to authenticated using(is_admin());
create function public.admin_record_subscriber(p_email text,p_name text,p_source text,p_consent text) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not is_admin() then raise exception 'Not authorized'; end if;
 if p_email is null or trim(p_email)!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or length(p_email)>254 or length(p_name)>100 or nullif(trim(p_source),'') is null or nullif(trim(p_consent),'') is null then raise exception 'Email, source and consent evidence are required'; end if;
 insert into mailing_subscribers(email,first_name,source,consent_text) values(lower(trim(p_email)),coalesce(p_name,''),p_source,p_consent)
 on conflict(email) do nothing; -- Imports must never overwrite an unsubscribe.
end $$;
revoke all on function public.admin_record_subscriber(text,text,text,text) from public,anon;
grant execute on function public.admin_record_subscriber(text,text,text,text) to authenticated;
create function public.set_my_marketing_preference(p_subscribed boolean) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare c customers%rowtype;
begin
 select * into c from customers where auth_user_id=auth.uid();
 if not found or not verified_customer_identity(c.email,auth.uid()) then raise exception 'Sign in with your verified email first'; end if;
 if p_subscribed then
 insert into mailing_subscribers(email,first_name,source,consent_text) values(lower(trim(c.email)),coalesce(c.first_name,''),'Patient account','I would like occasional news and updates from Ed Nicholls Acupuncture. I can unsubscribe at any time.')
 on conflict(email) do update set subscribed=true,unsubscribed_at=null,consent_recorded_at=now(),source=excluded.source,consent_text=excluded.consent_text;
 else update mailing_subscribers set subscribed=false,unsubscribed_at=now() where email=lower(trim(c.email)); end if;
end $$;
revoke all on function public.set_my_marketing_preference(boolean) from public,anon;
grant execute on function public.set_my_marketing_preference(boolean) to authenticated;
create function public.my_marketing_preference() returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select coalesce((select m.subscribed from mailing_subscribers m join customers c on lower(trim(c.email))=m.email where c.auth_user_id=auth.uid()),false)
$$;
revoke all on function public.my_marketing_preference() from public,anon;
grant execute on function public.my_marketing_preference() to authenticated;
create function public.unsubscribe_marketing(p_token uuid) returns void language sql security definer set search_path=public,pg_temp as $$
 update mailing_subscribers set subscribed=false,unsubscribed_at=now() where unsubscribe_token=p_token
$$;
revoke all on function public.unsubscribe_marketing(uuid) from public;
grant execute on function public.unsubscribe_marketing(uuid) to anon,authenticated;
create function public.admin_unsubscribe_marketing(p_id uuid) returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not is_admin() then raise exception 'Not authorized'; end if;
 update mailing_subscribers set subscribed=false,unsubscribed_at=now() where id=p_id;
end $$;
revoke all on function public.admin_unsubscribe_marketing(uuid) from public,anon;
grant execute on function public.admin_unsubscribe_marketing(uuid) to authenticated;
-- Account erasure must also suppress marketing delivery.
create function public.suppress_closed_account_marketing() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if new.email like '%@deleted.local' and old.email is distinct from new.email then
 update mailing_subscribers set subscribed=false,unsubscribed_at=now(),first_name='' where email=lower(trim(old.email));
 end if; return new;
end $$;
revoke all on function public.suppress_closed_account_marketing() from public,anon,authenticated;
create trigger suppress_closed_account_marketing after update of email on public.customers for each row execute function public.suppress_closed_account_marketing();
