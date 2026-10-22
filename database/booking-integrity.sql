-- Clinic booking rules. Existing appointments are not moved or revalidated.
alter table public.services add column if not exists start_capacity integer not null default 1 check (start_capacity > 0);
update public.services set concurrent_capacity = 3, start_capacity = 1 where slug = 'multi-bed';

create or replace function public.validate_booking_slot(p_service_id uuid, p_start timestamptz, p_end timestamptz, p_exclude uuid default null, p_check_lead boolean default true)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare s services%rowtype; local_start timestamp; local_end timestamp; occupied integer;
begin
  -- One clinic-wide lock also serialises different services that share the practitioner.
  perform pg_advisory_xact_lock(20371022);
  select * into s from services where id = p_service_id and active;
  if not found then raise exception 'Service is not available'; end if;
  if p_start is null or p_end is null or p_end - p_start <> make_interval(mins => s.duration_minutes) then
    raise exception 'Invalid appointment duration'; end if;
  if p_check_lead and p_start < now() + make_interval(hours => s.min_lead_hours) then
    raise exception 'This appointment needs at least % hours notice.', s.min_lead_hours; end if;
  local_start := p_start at time zone 'Europe/London';
  local_end := p_end at time zone 'Europe/London';
  if exists(select 1 from availability_overrides where date = local_start::date and type = 'closed') then
    raise exception 'The clinic is closed on this date'; end if;
  if local_start::date <> local_end::date or not exists (
    select 1 from availability_rules r where (r.service_id is null or r.service_id = s.id)
      and r.day_of_week = extract(dow from local_start)
      and local_start::time >= r.start_time and local_end::time <= r.end_time
      and mod(extract(epoch from (local_start::time - r.start_time)), coalesce(s.slot_interval_minutes,s.duration_minutes)*60) = 0
  ) then raise exception 'This appointment is outside the available clinic hours'; end if;
  if exists(select 1 from bookings b where b.id is distinct from p_exclude and b.status in ('confirmed','completed')
    and b.service_id <> s.id and b.starts_at < p_end and b.ends_at > p_start) then
    raise exception 'That slot is no longer available'; end if;
  select count(*) into occupied from bookings b where b.id is distinct from p_exclude and b.status in ('confirmed','completed')
    and b.service_id = s.id and b.starts_at = p_start;
  if occupied >= s.start_capacity then raise exception 'That slot is no longer available'; end if;
  if exists (
    with overlapping as (select starts_at,ends_at from bookings b where b.id is distinct from p_exclude
      and b.status in ('confirmed','completed') and b.service_id = s.id and b.starts_at < p_end and b.ends_at > p_start),
    points as (select p_start as t union select starts_at from overlapping where starts_at > p_start)
    select 1 from points where (select count(*) from overlapping where starts_at <= t and ends_at > t) >= s.concurrent_capacity
  ) then raise exception 'That slot is no longer available'; end if;
end $$;
revoke all on function public.validate_booking_slot(uuid,timestamptz,timestamptz,uuid,boolean) from public, anon, authenticated;
grant execute on function public.validate_booking_slot(uuid,timestamptz,timestamptz,uuid,boolean) to service_role;

create or replace function public.bookings_enforce_no_overlap() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status not in ('confirmed','completed') then return new; end if;
  if tg_op = 'UPDATE' then
    if (new.service_id,new.starts_at,new.ends_at) is not distinct from (old.service_id,old.starts_at,old.ends_at)
      and old.status in ('confirmed','completed') then return new; end if;
  end if;
  perform validate_booking_slot(new.service_id,new.starts_at,new.ends_at,new.id,not public.is_admin() and coalesce(current_setting('app.paid_checkout',true),'false') <> 'true');
  return new;
end $$;
drop trigger if exists bookings_lead_time_check on public.bookings;
drop trigger if exists bookings_no_overlap_check on public.bookings;
create trigger bookings_no_overlap_check before insert or update of starts_at,ends_at,service_id,status on public.bookings
for each row execute function public.bookings_enforce_no_overlap();

-- Credits can only be changed by trusted transactional operations.
drop policy if exists "customers create own packages" on public.customer_packages;
drop policy if exists "customers create own balances" on public.customer_package_balances;
drop policy if exists "balances update own or admin" on public.customer_package_balances;
drop policy if exists "customers cancel own bookings" on public.bookings;
drop policy if exists "bookings update own or admin" on public.bookings;
-- The existing signed-in cash booking path remains supported, with protected fields constrained.
alter policy "customers create own bookings" on public.bookings with check (
  customer_id in (select id from public.customers where auth_user_id = auth.uid())
  and customer_package_id is null and status = 'confirmed' and practitioner_journal is null and notes is null
);

create or replace function public.lookup_customer_by_email(p_email text) returns jsonb
language sql security invoker set search_path = public, pg_temp as $$ select null::jsonb $$;
create or replace function public.link_customer_to_auth() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_email text;
begin
  select email into v_email from auth.users where id = auth.uid() and email_confirmed_at is not null;
  if v_email is null then raise exception 'Please verify your email address first'; end if;
  update customers set auth_user_id = auth.uid() where lower(email) = lower(v_email) and auth_user_id is null;
end $$;
create or replace function public.verified_customer_identity(p_email text, p_auth uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select p_auth = auth.uid() and exists(select 1 from auth.users where id = auth.uid()
    and email_confirmed_at is not null and lower(email) = lower(p_email))
$$;
alter policy "customers insert own record" on public.customers with check (public.verified_customer_identity(email,auth_user_id));
alter policy "customers update own record" on public.customers using (auth_user_id = auth.uid())
with check (public.verified_customer_identity(email,auth_user_id));
alter function public.gen_cancellation_token() set search_path = public, pg_temp;
alter view public.booked_slots set (security_invoker = true);

CREATE OR REPLACE FUNCTION public.create_anonymous_booking(p_email text DEFAULT NULL::text, p_first_name text DEFAULT NULL::text, p_last_name text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_date_of_birth date DEFAULT NULL::date, p_gender text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_emergency_contact_name text DEFAULT NULL::text, p_emergency_contact_phone text DEFAULT NULL::text, p_emergency_contact_relationship text DEFAULT NULL::text, p_service_id uuid DEFAULT NULL::uuid, p_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_intake_response jsonb DEFAULT NULL::jsonb, p_electro_acupuncture_consent boolean DEFAULT NULL::boolean, p_general_consent_version text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer_id uuid;
  v_booking_id uuid;
  v_slot_taken boolean;
  v_min_lead_hours int;
begin
  if p_email is null or length(trim(p_email)) = 0 then
    raise exception 'create_anonymous_booking: p_email is required';
  end if;
  if p_service_id is null then
    raise exception 'create_anonymous_booking: p_service_id is required';
  end if;
  if p_starts_at is null or p_ends_at is null then
    raise exception 'create_anonymous_booking: p_starts_at and p_ends_at are required';
  end if;

  perform public.validate_booking_slot(p_service_id,p_starts_at,p_ends_at,null,coalesce(current_setting('app.paid_checkout',true),'false') <> 'true');

  insert into customers (
    email, first_name, last_name, phone,
    date_of_birth, gender, address,
    emergency_contact_name, emergency_contact_phone, emergency_contact_relationship,
    general_consent_at, general_consent_version
  )
  values (
    lower(trim(p_email)), p_first_name, p_last_name, p_phone,
    p_date_of_birth, p_gender, p_address,
    p_emergency_contact_name, p_emergency_contact_phone, p_emergency_contact_relationship,
    now(), p_general_consent_version
  )
  on conflict (email) do update set email = customers.email
  returning id into v_customer_id;

  insert into bookings (
    customer_id, service_id, starts_at, ends_at,
    intake_response, status,
    electro_acupuncture_consent, session_consent_ack_at,
    notes
  ) values (
    v_customer_id, p_service_id, p_starts_at, p_ends_at,
    p_intake_response, 'confirmed',
    p_electro_acupuncture_consent, now(),
    case when coalesce(current_setting('request.jwt.claims',true),'{}')::jsonb->>'role' = 'service_role' then p_notes else null end
  )
  returning id into v_booking_id;

  return v_booking_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.redeem_package_session(p_customer_package_id uuid, p_service_id uuid, p_starts_at timestamp with time zone, p_ends_at timestamp with time zone, p_intake_response jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer_id uuid;
  v_owner_auth_id uuid;
  v_caller_auth_id uuid := auth.uid();
  v_balance_id uuid;
  v_remaining int;
  v_slot_taken boolean;
  v_booking_id uuid;
begin
  if v_caller_auth_id is null then
    raise exception 'Not authenticated';
  end if;

  perform pg_advisory_xact_lock(20371022);

  -- Verify the package belongs to the caller's customer record
  select cp.customer_id, c.auth_user_id
    into v_customer_id, v_owner_auth_id
    from customer_packages cp
    join customers c on c.id = cp.customer_id
    where cp.id = p_customer_package_id
      and cp.status = 'active'
      and cp.expires_at > now();

  if not found then
    raise exception 'Package not found or not active';
  end if;
  if v_owner_auth_id is distinct from v_caller_auth_id then
    raise exception 'Package does not belong to this account';
  end if;

  -- Lock the balance row to prevent concurrent decrements
  select id, sessions_remaining
    into v_balance_id, v_remaining
    from customer_package_balances
    where customer_package_id = p_customer_package_id
      and service_id = p_service_id
    for update;

  if not found then
    raise exception 'No balance for this service in this package';
  end if;
  if v_remaining <= 0 then
    raise exception 'No sessions remaining for this service';
  end if;

  perform public.validate_booking_slot(p_service_id,p_starts_at,p_ends_at,null,coalesce(current_setting('app.paid_checkout',true),'false') <> 'true');

  -- Insert booking + decrement balance, atomic
  insert into bookings (
    customer_id, service_id, customer_package_id,
    starts_at, ends_at, intake_response, status,
    session_consent_ack_at
  ) values (
    v_customer_id, p_service_id, p_customer_package_id,
    p_starts_at, p_ends_at, p_intake_response, 'confirmed',
    now()
  )
  returning id into v_booking_id;

  update customer_package_balances
    set sessions_remaining = sessions_remaining - 1
    where id = v_balance_id;

  return v_booking_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_booking_by_token(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_booking record;
  v_balance_id uuid;
  v_session_returned boolean := false;
  v_notify_url text := 'https://bdzasnbzyfkqojqqucil.supabase.co/functions/v1/send-cancellation-email';
  v_anon_key text := 'sb_publishable_XOH_-PTfkNsPhwY5eMV_Tg_M9GPbWE5';
begin
  select * into v_booking
    from bookings where cancellation_token = p_token limit 1 for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Booking not found or already cancelled.');
  end if;
  if v_booking.status = 'cancelled' then
    return jsonb_build_object('ok', true, 'message', 'This booking is already cancelled.',
      'already_cancelled', true, 'starts_at', v_booking.starts_at);
  end if;
  if v_booking.status = 'completed' then
    return jsonb_build_object('ok', false, 'error', 'This session has already taken place and cannot be cancelled.');
  end if;

  update bookings set status = 'cancelled' where id = v_booking.id;

  if v_booking.customer_package_id is not null then
    select id into v_balance_id
      from customer_package_balances
      where customer_package_id = v_booking.customer_package_id
        and service_id = v_booking.service_id
      limit 1;
    if found then
      update customer_package_balances
        set sessions_remaining = sessions_remaining + 1
        where id = v_balance_id;
      v_session_returned := true;
    end if;
  end if;

  -- Fire-and-forget admin notification. pg_net returns immediately with a
  -- request_id; delivery happens on Supabase's background workers. Any
  -- failure in the edge function is logged there, not here.
  begin
    perform net.http_post(
      url := v_notify_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_anon_key
      ),
      body := jsonb_build_object('booking_id', v_booking.id)
    );
  exception when others then
    -- Don't let notify failure break the cancellation
    raise warning 'Admin notify failed: %', sqlerrm;
  end;

  return jsonb_build_object(
    'ok', true,
    'message', 'Booking cancelled.',
    'starts_at', v_booking.starts_at,
    'session_returned_to_package', v_session_returned
  );
end;
$function$;

revoke execute on function public.run_retention_sweep() from public,anon,authenticated;

revoke execute on function public.rls_auto_enable() from public,anon,authenticated;

revoke execute on function public.log_change() from public,anon,authenticated;

revoke execute on function public.bookings_enforce_lead_time() from public,anon,authenticated;

revoke execute on function public.bookings_enforce_no_overlap() from public,anon,authenticated;

revoke execute on function public.link_customer_to_auth() from public,anon;
grant execute on function public.link_customer_to_auth() to authenticated;

revoke execute on function public.export_my_data() from public,anon;
grant execute on function public.export_my_data() to authenticated;

revoke execute on function public.delete_my_account() from public,anon;
grant execute on function public.delete_my_account() to authenticated;

revoke execute on function public.redeem_package_session(p_customer_package_id uuid, p_service_id uuid, p_starts_at timestamp with time zone, p_ends_at timestamp with time zone, p_intake_response jsonb) from public,anon;
grant execute on function public.redeem_package_session(p_customer_package_id uuid, p_service_id uuid, p_starts_at timestamp with time zone, p_ends_at timestamp with time zone, p_intake_response jsonb) to authenticated;
