create table public.internal_settings (name text primary key,value text not null);
alter table public.internal_settings enable row level security;
revoke all on public.internal_settings from anon,authenticated;
grant all on public.internal_settings to service_role;
insert into public.internal_settings values('notification_token',gen_random_uuid()::text||gen_random_uuid()::text);
create table public.notification_jobs (
 id uuid primary key default gen_random_uuid(), kind text not null, reference_id uuid not null,
 audience text not null check(audience in ('patient','admin')), status text not null default 'pending',
 created_at timestamptz not null default now(), next_attempt_at timestamptz not null default now(),
 attempts integer not null default 0, sent_at timestamptz, last_error text,
 unique(kind,reference_id,audience)
);
alter table public.notification_jobs enable row level security;
revoke all on public.notification_jobs from anon,authenticated;
grant all on public.notification_jobs to service_role;
grant select on public.notification_jobs to authenticated;
create policy "admin read delivery status" on public.notification_jobs for select to authenticated using(public.is_admin());
create index notification_jobs_pending on public.notification_jobs(next_attempt_at) where status='pending';

create function public.wake_notification_worker() returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
 perform net.http_post(url:='https://bdzasnbzyfkqojqqucil.supabase.co/functions/v1/send-booking-reminders',
   headers:=jsonb_build_object('Content-Type','application/json','X-Internal-Token',(select value from internal_settings where name='notification_token')),
   body:='{}'::jsonb);
end $$;
revoke all on function public.wake_notification_worker() from public,anon,authenticated;
grant execute on function public.wake_notification_worker() to service_role;

create function public.booking_notifications() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare kind text;
begin
 if tg_op='INSERT' and new.status='confirmed' then kind:='booking';
 elsif tg_op='UPDATE' and new.status='cancelled' and old.status<>'cancelled' then
   kind:='cancellation';
   if new.customer_package_id is not null then
     update customer_package_balances set sessions_remaining=sessions_remaining+1
     where customer_package_id=new.customer_package_id and service_id=new.service_id;
   end if;
 else return new; end if;
 insert into notification_jobs(kind,reference_id,audience) values(kind,new.id,'patient'),(kind,new.id,'admin') on conflict do nothing;
 perform wake_notification_worker();
 return new;
end $$;
revoke all on function public.booking_notifications() from public,anon,authenticated;
drop trigger if exists "send-booking-email-on-insert" on public.bookings;
create trigger booking_notifications after insert or update of status on public.bookings for each row execute function public.booking_notifications();

create or replace function public.cancel_booking_by_token(p_token text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b bookings%rowtype;
begin
 perform pg_advisory_xact_lock(20371022);
 select * into b from bookings where cancellation_token=p_token for update;
 if not found then return jsonb_build_object('ok',false,'error','Booking not found.'); end if;
 if b.status='cancelled' then return jsonb_build_object('ok',true,'already_cancelled',true,'starts_at',b.starts_at); end if;
 if b.status<>'confirmed' then return jsonb_build_object('ok',false,'error','Only a confirmed appointment can be cancelled.'); end if;
 update bookings set status='cancelled' where id=b.id;
 return jsonb_build_object('ok',true,'starts_at',b.starts_at,'session_returned_to_package',b.customer_package_id is not null);
end $$;

create function public.package_notification() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if new.status='active' then
 insert into notification_jobs(kind,reference_id,audience) values('package',new.id,'patient') on conflict do nothing;
 perform wake_notification_worker();
 end if;
 return new;
end $$;
revoke all on function public.package_notification() from public,anon,authenticated;
create trigger package_notification after insert on public.customer_packages for each row execute function public.package_notification();

create function public.claim_notifications() returns setof public.notification_jobs language plpgsql security definer set search_path=public,pg_temp as $$
begin
 insert into notification_jobs(kind,reference_id,audience)
 select 'reminder',id,'patient' from bookings where status='confirmed' and reminder_sent_at is null
 and starts_at>now() and starts_at<=now()+interval '24 hours' on conflict do nothing;
 update notification_jobs set status='needs_review',last_error='Automatic retry limit reached. Check delivery before retrying.'
 where status='pending' and (attempts>=10 or (attempts>0 and created_at<now()-interval '23 hours'));
 return query with due as (select id from notification_jobs where status='pending' and next_attempt_at<=now()
 order by created_at for update skip locked limit 25)
 update notification_jobs n set attempts=n.attempts+1,next_attempt_at=now()+interval '10 minutes'
 from due where n.id=due.id returning n.*;
end $$;
revoke all on function public.claim_notifications() from public,anon,authenticated;
grant execute on function public.claim_notifications() to service_role;

-- Do not allow cancelled package bookings to be restored and refunded a second time.
create function public.prevent_booking_resurrection() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if old.status='cancelled' and new.status<>'cancelled' then raise exception 'Please create a new booking instead of restoring a cancelled booking'; end if;
 if old.customer_package_id is not null and (new.customer_package_id,new.customer_id,new.service_id) is distinct from (old.customer_package_id,old.customer_id,old.service_id) then
 raise exception 'Cancel and rebook to change a package booking'; end if;
 return new;
end $$;
create trigger prevent_booking_resurrection before update on public.bookings for each row execute function public.prevent_booking_resurrection();
revoke all on function public.prevent_booking_resurrection() from public,anon,authenticated;

create function public.admin_operational_issues() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not public.is_admin() then raise exception 'Not authorized'; end if;
 return jsonb_build_object(
 'payments',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'session',stripe_session_id,'status',status,'reason',failure_reason,'created_at',created_at)),'[]'::jsonb)
 from pending_checkouts where status='refund_required' or (status='pending' and payment_intent is not null)),
 'emails',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'kind',kind,'reference_id',reference_id,'status',status,'attempts',attempts,'error',last_error)),'[]'::jsonb)
 from notification_jobs where status='needs_review' or (status='pending' and (attempts>0 or created_at<now()-interval '10 minutes'))));
end $$;
revoke all on function public.admin_operational_issues() from public,anon;
grant execute on function public.admin_operational_issues() to authenticated;
