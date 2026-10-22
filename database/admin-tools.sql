-- Private custom entitlements are separate from the public package catalogue.
alter table public.customer_packages alter column package_id drop not null;
alter table public.customer_packages add column custom_name text;
alter table public.customer_packages add column assignment_key uuid unique;
alter table public.customer_packages add constraint custom_package_name_required check(package_id is not null or nullif(trim(custom_name),'') is not null);

create function public.admin_assign_package(p_customer_id uuid,p_name text,p_credits jsonb,p_amount integer,p_request_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare result uuid; item jsonb; days integer;
begin
 if not is_admin() then raise exception 'Not authorized'; end if;
 perform pg_advisory_xact_lock(20371022);
 select id into result from customer_packages where assignment_key=p_request_id;
 if found then return result; end if;
 if p_request_id is null or nullif(trim(p_name),'') is null or length(p_name)>100 or p_amount is null or p_amount<0 then raise exception 'Enter a name and valid amount paid'; end if;
 if not exists(select 1 from customers where id=p_customer_id and email not like '%@deleted.local') then raise exception 'Patient not found'; end if;
 if jsonb_typeof(p_credits) is distinct from 'array' or jsonb_array_length(p_credits)=0 or jsonb_array_length(p_credits)>20 then raise exception 'Add treatment credits'; end if;
 for item in select * from jsonb_array_elements(p_credits) loop
  if not exists(select 1 from services where id=(item->>'service_id')::uuid and active) or (item->>'quantity')::integer not between 1 and 100 or item->>'quantity' is null then raise exception 'Invalid treatment credits'; end if;
 end loop;
 if (select count(*)<>count(distinct value->>'service_id') from jsonb_array_elements(p_credits)) then raise exception 'Duplicate treatment type'; end if;
 select min(expiry_days) into days from packages where active;
 if days is null or exists(select 1 from packages where active and expiry_days<>days) then raise exception 'Standard package expiry needs review'; end if;
 insert into customer_packages(customer_id,custom_name,expires_at,amount_paid_pence,assignment_key)
 values(p_customer_id,trim(p_name),now()+make_interval(days=>days),p_amount,p_request_id) returning id into result;
 insert into customer_package_balances(customer_package_id,service_id,sessions_remaining)
 select result,(value->>'service_id')::uuid,(value->>'quantity')::integer from jsonb_array_elements(p_credits);
 return result;
end $$;
revoke all on function public.admin_assign_package(uuid,text,jsonb,integer,uuid) from public,anon;
grant execute on function public.admin_assign_package(uuid,text,jsonb,integer,uuid) to authenticated;

create table public.booking_time_changes(
 id uuid primary key default gen_random_uuid(),booking_id uuid not null references bookings(id),
 old_starts_at timestamptz not null,new_starts_at timestamptz not null,new_ends_at timestamptz not null,
 changed_at timestamptz not null default now(),changed_by uuid
);
alter table public.booking_time_changes enable row level security;
revoke all on public.booking_time_changes from anon,authenticated;
grant select on public.booking_time_changes to authenticated;
grant all on public.booking_time_changes to service_role;
create policy "admin read appointment changes" on public.booking_time_changes for select to authenticated using(is_admin());
create function public.notify_booking_time_change() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare change_id uuid;
begin
 if new.status='confirmed' and (new.starts_at,new.ends_at) is distinct from (old.starts_at,old.ends_at) then
  insert into booking_time_changes(booking_id,old_starts_at,new_starts_at,new_ends_at,changed_by) values(new.id,old.starts_at,new.starts_at,new.ends_at,auth.uid()) returning id into change_id;
  insert into notification_jobs(kind,reference_id,audience) values('reschedule',change_id,'patient');
  -- Reset the reminder lifecycle for the new appointment without reusing a provider idempotency key.
  update notification_jobs set kind='previous_reminder_'||id::text,status=case when status='pending' then 'skipped' else status end where kind='reminder' and reference_id=new.id;
  update bookings set reminder_sent_at=null where id=new.id;
  perform wake_notification_worker();
 end if;
 return new;
end $$;
revoke all on function public.notify_booking_time_change() from public,anon,authenticated;
create trigger notify_booking_time_change after update of starts_at,ends_at on public.bookings for each row execute function public.notify_booking_time_change();
create function public.admin_reschedule_booking(p_booking_id uuid,p_expected_start timestamptz,p_start timestamptz)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare b bookings%rowtype; duration integer;
begin
 if not is_admin() then raise exception 'Not authorized'; end if;
 perform pg_advisory_xact_lock(20371022);
 select * into b from bookings where id=p_booking_id for update;
 if not found or b.status<>'confirmed' then raise exception 'Only confirmed appointments can be moved'; end if;
 if b.starts_at is distinct from p_expected_start then raise exception 'This appointment changed. Refresh before trying again'; end if;
 if p_start is null or p_start<=now() then raise exception 'Choose a future appointment'; end if;
 if p_start=b.starts_at then return; end if;
 select duration_minutes into duration from services where id=b.service_id;
 perform validate_booking_slot(b.service_id,p_start,p_start+make_interval(mins=>duration),b.id,false);
 update bookings set starts_at=p_start,ends_at=p_start+make_interval(mins=>duration) where id=b.id;
end $$;
revoke all on function public.admin_reschedule_booking(uuid,timestamptz,timestamptz) from public,anon;
grant execute on function public.admin_reschedule_booking(uuid,timestamptz,timestamptz) to authenticated;
