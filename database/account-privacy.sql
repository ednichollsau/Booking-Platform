create table public.account_deletion_requests (user_id uuid primary key,requested_at timestamptz not null default now(),completed_at timestamptz,last_error text);
alter table public.account_deletion_requests enable row level security;
revoke all on public.account_deletion_requests from anon,authenticated;
grant all on public.account_deletion_requests to service_role;
alter table public.customers add column clinical_retention_until timestamptz;

create or replace function public.log_change() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare old_record jsonb; new_record jsonb; rid uuid;
begin
 if tg_op<>'INSERT' then old_record:=jsonb_build_object('id',old.id); end if;
 if tg_op<>'DELETE' then new_record:=jsonb_build_object('id',new.id); end if;
 -- Keep an audit of actions, without duplicating clinical or contact details into logs.
 rid:=case when tg_op='DELETE' then old.id else new.id end;
 insert into audit_log(actor_id,action,table_name,row_id,old_data,new_data) values(auth.uid(),tg_op,tg_table_name,rid,old_record,new_record);
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;
create or replace function public.delete_my_account() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare c customers%rowtype; count_cancelled integer; uid uuid:=auth.uid();
begin
 if uid is null then raise exception 'Not authenticated'; end if;
 if public.is_admin() then raise exception 'Please contact support to close the administrator account'; end if;
 perform pg_advisory_xact_lock(20371022);
 select * into c from customers where auth_user_id=uid for update;
 insert into account_deletion_requests(user_id) values(uid) on conflict do nothing;
 if c.id is not null then
   update bookings set status='cancelled' where customer_id=c.id and status='confirmed' and starts_at>now();
   get diagnostics count_cancelled=row_count;
   update customers set clinical_retention_until=greatest(
     coalesce((select max(starts_at) from bookings where customer_id=c.id),c.created_at)+interval '8 years',
     c.date_of_birth::timestamptz+interval '21 years'),
     email='deleted+'||c.id||'@deleted.local',first_name='Deleted',last_name='User',phone=null,date_of_birth=null,gender=null,address=null,
     emergency_contact_name=null,emergency_contact_phone=null,emergency_contact_relationship=null,notes=null,auth_user_id=null
   where id=c.id;
   update audit_log set actor_email=null,old_data=null,new_data=null where actor_id=uid or (table_name='customers' and row_id=c.id)
     or (table_name='bookings' and row_id in(select id from bookings where customer_id=c.id));
   -- Pending checkout data must not silently restore a deleted customer.
   update pending_checkouts set payload='{}'::jsonb,status=case when payment_intent is not null then 'refund_required' else status end,
     failure_reason='Account deletion requested' where status='pending' and (payload->>'customer_id'=c.id::text or lower(payload->>'email')=lower(c.email));
 end if;
 perform wake_notification_worker();
 return jsonb_build_object('ok',true,'cancelled_bookings',coalesce(count_cancelled,0),
 'note','Your account closure has been requested and personal contact details removed. Clinical records remain subject to the practice retention policy.');
end $$;
revoke all on function public.delete_my_account() from public,anon;
grant execute on function public.delete_my_account() to authenticated;

create or replace function public.export_my_data() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare cid uuid;
begin
 if auth.uid() is null then raise exception 'Not authenticated'; end if;
 select id into cid from customers where auth_user_id=auth.uid();
 return jsonb_build_object('exported_at',now(),'customer',(select to_jsonb(c) from customers c where id=cid),
 'bookings',(select coalesce(jsonb_agg(to_jsonb(b)-'cancellation_token'),'[]'::jsonb) from bookings b where customer_id=cid),
 'packages',(select coalesce(jsonb_agg(to_jsonb(cp)),'[]'::jsonb) from customer_packages cp where customer_id=cid),
 'package_balances',(select coalesce(jsonb_agg(to_jsonb(b)),'[]'::jsonb) from customer_package_balances b where customer_package_id in(select id from customer_packages where customer_id=cid)));
end $$;
revoke all on function public.export_my_data() from public,anon;
grant execute on function public.export_my_data() to authenticated;

create function public.protect_customer_notes() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if current_user='authenticated' and not public.is_admin() then
   if tg_op='INSERT' then
     if new.notes is not null or new.clinical_retention_until is not null then raise exception 'Protected fields'; end if;
   elsif (new.notes,new.clinical_retention_until) is distinct from (old.notes,old.clinical_retention_until) then raise exception 'Protected fields'; end if;
 end if;
 return new;
end $$;
create trigger protect_customer_notes before insert or update on public.customers for each row execute function public.protect_customer_notes();
revoke all on function public.protect_customer_notes() from public,anon,authenticated;

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select exists(select 1 from auth.users where id=auth.uid() and email='acu@ednicholls.com' and email_confirmed_at is not null)
$$;
create or replace function public.verified_customer_identity(p_email text,p_auth uuid) returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select p_auth=auth.uid() and exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null and lower(email)=lower(p_email))
 and not exists(select 1 from account_deletion_requests where user_id=auth.uid())
$$;
revoke all on function public.verified_customer_identity(text,uuid) from public,anon;
grant execute on function public.verified_customer_identity(text,uuid) to authenticated,service_role;
