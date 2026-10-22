create role anon; create role authenticated; create role service_role bypassrls; create schema auth; create schema net;
create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
create function net.http_post(url text, headers jsonb, body jsonb) returns bigint language sql as $$select 1::bigint$$;
create sequence public.audit_log_id_seq;
CREATE OR REPLACE FUNCTION public.gen_cancellation_token()
 RETURNS text
 LANGUAGE sql
AS $function$
  select replace(gen_random_uuid()::text, '-', '');
$function$;

create table public.audit_log(id bigint default nextval('audit_log_id_seq'::regclass) not null,occurred_at timestamp with time zone default now() not null,actor_id uuid,actor_email text,action text not null,table_name text not null,row_id uuid,new_data jsonb,old_data jsonb);
create table public.availability_overrides(id uuid default gen_random_uuid() not null,date date not null,type text not null,start_time time without time zone,end_time time without time zone,reason text);
create table public.availability_rules(id uuid default gen_random_uuid() not null,day_of_week integer not null,start_time time without time zone not null,end_time time without time zone not null,service_id uuid);

create table public.bookings(id uuid default gen_random_uuid() not null,customer_id uuid not null,service_id uuid not null,customer_package_id uuid,starts_at timestamp with time zone not null,ends_at timestamp with time zone not null,status text default 'confirmed'::text not null,intake_response jsonb,notes text,created_at timestamp with time zone default now() not null,cancellation_token text default gen_cancellation_token(),practitioner_journal text,electro_acupuncture_consent boolean,session_consent_ack_at timestamp with time zone,reminder_sent_at timestamp with time zone);
create table public.customer_package_balances(id uuid default gen_random_uuid() not null,customer_package_id uuid not null,service_id uuid not null,sessions_remaining integer not null);
create table public.customer_packages(id uuid default gen_random_uuid() not null,customer_id uuid not null,package_id uuid not null,purchased_at timestamp with time zone default now() not null,expires_at timestamp with time zone not null,amount_paid_pence integer not null,stripe_payment_id text,status text default 'active'::text not null);
create table public.customers(id uuid default gen_random_uuid() not null,auth_user_id uuid,email text not null,first_name text,last_name text,phone text,notes text,created_at timestamp with time zone default now() not null,date_of_birth date,gender text,address text,emergency_contact_name text,emergency_contact_phone text,emergency_contact_relationship text,general_consent_at timestamp with time zone,general_consent_version text);
create table public.package_contents(id uuid default gen_random_uuid() not null,package_id uuid not null,service_id uuid not null,quantity integer not null);
create table public.packages(id uuid default gen_random_uuid() not null,slug text not null,name text not null,description text,total_sessions integer not null,price_pence integer not null,expiry_days integer default 365 not null,active boolean default true not null,created_at timestamp with time zone default now() not null);
create table public.services(id uuid default gen_random_uuid() not null,slug text not null,name text not null,description text,duration_minutes integer not null,price_pence integer not null,active boolean default true not null,created_at timestamp with time zone default now() not null,slot_interval_minutes integer,concurrent_capacity integer default 1 not null,min_lead_hours integer default 0 not null);
alter table public.services add constraint services_pkey PRIMARY KEY (id);
alter table public.services add constraint services_slug_key UNIQUE (slug);
alter table public.packages add constraint packages_pkey PRIMARY KEY (id);
alter table public.packages add constraint packages_slug_key UNIQUE (slug);
alter table public.package_contents add constraint package_contents_quantity_check CHECK ((quantity > 0));
alter table public.package_contents add constraint package_contents_pkey PRIMARY KEY (id);
alter table public.package_contents add constraint package_contents_package_id_service_id_key UNIQUE (package_id, service_id);
alter table public.package_contents add constraint package_contents_package_id_fkey FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE CASCADE;
alter table public.package_contents add constraint package_contents_service_id_fkey FOREIGN KEY (service_id) REFERENCES services(id) ON DELETE RESTRICT;
alter table public.customers add constraint customers_pkey PRIMARY KEY (id);
alter table public.customers add constraint customers_auth_user_id_key UNIQUE (auth_user_id);
alter table public.customers add constraint customers_email_key UNIQUE (email);
alter table public.customers add constraint customers_auth_user_id_fkey FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.customer_packages add constraint customer_packages_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'active'::text, 'expired'::text, 'refunded'::text])));
alter table public.customer_packages add constraint customer_packages_pkey PRIMARY KEY (id);
alter table public.customer_packages add constraint customer_packages_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE;
alter table public.customer_packages add constraint customer_packages_package_id_fkey FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE RESTRICT;
alter table public.customer_package_balances add constraint customer_package_balances_sessions_remaining_check CHECK ((sessions_remaining >= 0));
alter table public.customer_package_balances add constraint customer_package_balances_pkey PRIMARY KEY (id);
alter table public.customer_package_balances add constraint customer_package_balances_customer_package_id_service_id_key UNIQUE (customer_package_id, service_id);
alter table public.customer_package_balances add constraint customer_package_balances_customer_package_id_fkey FOREIGN KEY (customer_package_id) REFERENCES customer_packages(id) ON DELETE CASCADE;
alter table public.customer_package_balances add constraint customer_package_balances_service_id_fkey FOREIGN KEY (service_id) REFERENCES services(id) ON DELETE RESTRICT;
alter table public.bookings add constraint bookings_status_check CHECK ((status = ANY (ARRAY['confirmed'::text, 'cancelled'::text, 'completed'::text, 'no_show'::text])));
alter table public.bookings add constraint bookings_check CHECK ((ends_at > starts_at));
alter table public.bookings add constraint bookings_pkey PRIMARY KEY (id);
alter table public.bookings add constraint bookings_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE RESTRICT;
alter table public.bookings add constraint bookings_service_id_fkey FOREIGN KEY (service_id) REFERENCES services(id) ON DELETE RESTRICT;
alter table public.bookings add constraint bookings_customer_package_id_fkey FOREIGN KEY (customer_package_id) REFERENCES customer_packages(id) ON DELETE SET NULL;
alter table public.availability_rules add constraint availability_rules_day_of_week_check CHECK (((day_of_week >= 0) AND (day_of_week <= 6)));
alter table public.availability_rules add constraint availability_rules_check CHECK ((end_time > start_time));
alter table public.availability_rules add constraint availability_rules_pkey PRIMARY KEY (id);
alter table public.availability_overrides add constraint availability_overrides_type_check CHECK ((type = ANY (ARRAY['closed'::text, 'open'::text])));
alter table public.availability_overrides add constraint availability_overrides_pkey PRIMARY KEY (id);
alter table public.bookings add constraint bookings_cancellation_token_key UNIQUE (cancellation_token);
alter table public.availability_rules add constraint availability_rules_service_id_fkey FOREIGN KEY (service_id) REFERENCES services(id);
alter table public.audit_log add constraint audit_log_action_check CHECK ((action = ANY (ARRAY['INSERT'::text, 'UPDATE'::text, 'DELETE'::text])));
alter table public.audit_log add constraint audit_log_pkey PRIMARY KEY (id);
CREATE OR REPLACE FUNCTION public.bookings_enforce_lead_time()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_min_lead_hours int;
  v_role text;
begin
  -- Bypass for service_role (webhooks) and admin (Ed booking walk-ins)
  select current_setting('request.jwt.claims', true)::jsonb ->> 'role' into v_role;
  if v_role = 'service_role' then
    return new;
  end if;
  if public.is_admin() then
    return new;
  end if;

  select min_lead_hours into v_min_lead_hours from services where id = new.service_id;
  if v_min_lead_hours is not null and v_min_lead_hours > 0
     and new.starts_at < now() + (v_min_lead_hours || ' hours')::interval then
    raise exception 'This appointment needs at least % hours notice.', v_min_lead_hours;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.bookings_enforce_no_overlap()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text;
  v_conflict boolean;
begin
  -- Bypass for service_role (webhook/RPC) and admin
  select current_setting('request.jwt.claims', true)::jsonb ->> 'role' into v_role;
  if v_role = 'service_role' then return new; end if;
  if public.is_admin() then return new; end if;

  -- Lock so concurrent inserts by different users serialise
  perform pg_advisory_xact_lock(hashtextextended(new.service_id::text || new.starts_at::text, 0));

  select exists (
    select 1 from bookings
    where status in ('confirmed','completed')
      and id is distinct from new.id
      and starts_at < new.ends_at
      and ends_at > new.starts_at
  ) into v_conflict;

  if v_conflict then
    raise exception 'That slot is no longer available';
  end if;
  return new;
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
    from bookings where cancellation_token = p_token limit 1;

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
  -- Idempotency: if a booking with the same notes value already exists,
  -- return its id rather than creating a duplicate
  if p_notes is not null and length(p_notes) > 0 then
    select id into v_booking_id from bookings where notes = p_notes limit 1;
    if v_booking_id is not null then
      return v_booking_id;
    end if;
  end if;

  if p_email is null or length(trim(p_email)) = 0 then
    raise exception 'create_anonymous_booking: p_email is required';
  end if;
  if p_service_id is null then
    raise exception 'create_anonymous_booking: p_service_id is required';
  end if;
  if p_starts_at is null or p_ends_at is null then
    raise exception 'create_anonymous_booking: p_starts_at and p_ends_at are required';
  end if;

  select min_lead_hours into v_min_lead_hours from services where id = p_service_id;
  if v_min_lead_hours is not null and v_min_lead_hours > 0
     and p_starts_at < now() + (v_min_lead_hours || ' hours')::interval then
    raise exception 'This appointment needs at least % hours notice.', v_min_lead_hours;
  end if;

  -- Lock rows so concurrent bookings for the same time slot serialise
  perform pg_advisory_xact_lock(hashtextextended(p_service_id::text || p_starts_at::text, 0));

  select exists (
    select 1 from bookings
    where status in ('confirmed','completed')
      and starts_at < p_ends_at
      and ends_at > p_starts_at
  ) into v_slot_taken;

  if v_slot_taken then
    raise exception 'That slot is no longer available';
  end if;

  insert into customers (
    email, first_name, last_name, phone,
    date_of_birth, gender, address,
    emergency_contact_name, emergency_contact_phone, emergency_contact_relationship,
    general_consent_at, general_consent_version
  )
  values (
    lower(p_email), p_first_name, p_last_name, p_phone,
    p_date_of_birth, p_gender, p_address,
    p_emergency_contact_name, p_emergency_contact_phone, p_emergency_contact_relationship,
    now(), p_general_consent_version
  )
  on conflict (email) do update set
    first_name = coalesce(excluded.first_name, customers.first_name),
    last_name = coalesce(excluded.last_name, customers.last_name),
    phone = coalesce(excluded.phone, customers.phone),
    date_of_birth = coalesce(excluded.date_of_birth, customers.date_of_birth),
    gender = coalesce(excluded.gender, customers.gender),
    address = coalesce(excluded.address, customers.address),
    emergency_contact_name = coalesce(excluded.emergency_contact_name, customers.emergency_contact_name),
    emergency_contact_phone = coalesce(excluded.emergency_contact_phone, customers.emergency_contact_phone),
    emergency_contact_relationship = coalesce(excluded.emergency_contact_relationship, customers.emergency_contact_relationship),
    general_consent_at = coalesce(customers.general_consent_at, now()),
    general_consent_version = coalesce(customers.general_consent_version, excluded.general_consent_version)
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
    p_notes
  )
  returning id into v_booking_id;

  return v_booking_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.delete_my_account()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer_id uuid;
  v_cancelled_count int;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select id into v_customer_id from customers where auth_user_id = auth.uid();
  if v_customer_id is null then
    return jsonb_build_object('ok', false, 'error', 'No record found for this account');
  end if;

  -- Cancel future confirmed bookings
  update bookings
    set status = 'cancelled'
    where customer_id = v_customer_id
      and status = 'confirmed'
      and starts_at > now();
  get diagnostics v_cancelled_count = row_count;

  -- Anonymise personally identifying data on the customer record.
  -- Bookings + intake_response retained (clinical record).
  update customers
    set email = 'deleted+' || v_customer_id::text || '@deleted.local',
        first_name = 'Deleted',
        last_name = 'User',
        phone = null,
        date_of_birth = null,
        gender = null,
        address = null,
        emergency_contact_name = null,
        emergency_contact_phone = null,
        emergency_contact_relationship = null,
        notes = null,
        auth_user_id = null
    where id = v_customer_id;

  return jsonb_build_object(
    'ok', true,
    'cancelled_bookings', v_cancelled_count,
    'note', 'Personal identifiers removed. Clinical session records retained for 8 years per UK retention obligations.'
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.export_my_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer_id uuid;
  v_data jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select id into v_customer_id from customers where auth_user_id = auth.uid();
  if v_customer_id is null then
    return jsonb_build_object('exported_at', now(), 'note', 'No record found for this account.');
  end if;

  select jsonb_build_object(
    'exported_at', now(),
    'customer', (select to_jsonb(c) from customers c where c.id = v_customer_id),
    'bookings', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'id', b.id,
          'service', (select name from services where id = b.service_id),
          'starts_at', b.starts_at,
          'ends_at', b.ends_at,
          'status', b.status,
          'intake_response', b.intake_response
        ) order by b.starts_at desc
      ), '[]'::jsonb)
      from bookings b
      where b.customer_id = v_customer_id
    ),
    'packages', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'package', (select name from packages where id = cp.package_id),
          'purchased_at', cp.purchased_at,
          'expires_at', cp.expires_at,
          'amount_paid_pence', cp.amount_paid_pence,
          'status', cp.status
        )
      ), '[]'::jsonb)
      from customer_packages cp
      where cp.customer_id = v_customer_id
    )
  ) into v_data;

  return v_data;
end;
$function$;

CREATE OR REPLACE FUNCTION public.gen_cancellation_token()
 RETURNS text
 LANGUAGE sql
AS $function$
  select replace(gen_random_uuid()::text, '-', '');
$function$;

CREATE OR REPLACE FUNCTION public.get_booked_slots(p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS TABLE(starts_at timestamp with time zone, ends_at timestamp with time zone, service_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select b.starts_at, b.ends_at, b.service_id
    from bookings b
   where b.status in ('confirmed','completed')
     and (p_from is null or b.starts_at >= p_from)
     and (p_to   is null or b.starts_at <  p_to);
$function$;

CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from auth.users
    where id = auth.uid()
    and email = 'acu@ednicholls.com'
  );
$function$;

CREATE OR REPLACE FUNCTION public.link_customer_to_auth()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_email text;
begin
  select email into v_email from auth.users where id = auth.uid();
  if v_email is null then return; end if;

  update customers
    set auth_user_id = auth.uid()
    where lower(email) = lower(v_email) and auth_user_id is null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.log_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_email text;
  v_row_id uuid;
begin
  if v_actor is not null then
    select email into v_email from auth.users where id = v_actor;
  end if;

  if tg_op = 'DELETE' then
    v_row_id := (old.id)::uuid;
    insert into audit_log (actor_id, actor_email, action, table_name, row_id, old_data)
    values (v_actor, v_email, tg_op, tg_table_name, v_row_id, to_jsonb(old));
    return old;
  elsif tg_op = 'INSERT' then
    v_row_id := (new.id)::uuid;
    insert into audit_log (actor_id, actor_email, action, table_name, row_id, new_data)
    values (v_actor, v_email, tg_op, tg_table_name, v_row_id, to_jsonb(new));
    return new;
  else
    v_row_id := (new.id)::uuid;
    insert into audit_log (actor_id, actor_email, action, table_name, row_id, new_data, old_data)
    values (v_actor, v_email, tg_op, tg_table_name, v_row_id, to_jsonb(new), to_jsonb(old));
    return new;
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.lookup_customer_by_email(p_email text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v record;
begin
  if p_email is null or length(trim(p_email)) = 0 then
    return null;
  end if;

  select email, first_name, last_name into v
    from customers
    where lower(email) = lower(trim(p_email))
      and email not like 'deleted+%@deleted.local'
    limit 1;

  if not found then
    return null;
  end if;

  -- Note: only email + first/last name are returned. The booking RPC
  -- uses email as the lookup key and reads the rest of the customer
  -- record server-side, so the frontend never sees full PII.
  return jsonb_build_object(
    'email', v.email,
    'first_name', v.first_name,
    'last_name', v.last_name
  );
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

  -- Verify the package belongs to the caller's customer record
  select cp.customer_id, c.auth_user_id
    into v_customer_id, v_owner_auth_id
    from customer_packages cp
    join customers c on c.id = cp.customer_id
    where cp.id = p_customer_package_id
      and cp.status = 'active';

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

  -- Slot overlap check
  select exists (
    select 1 from bookings
    where status in ('confirmed','completed')
      and starts_at < p_ends_at
      and ends_at > p_starts_at
  ) into v_slot_taken;
  if v_slot_taken then
    raise exception 'That slot is no longer available';
  end if;

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

CREATE OR REPLACE FUNCTION public.run_retention_sweep()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_anonymised int := 0;
  v_audit_pruned int := 0;
  v_minors_held int := 0;
begin
  -- Count how many records we're holding back because they belong to
  -- patients who were minors and are still within the 21-year window
  select count(*) into v_minors_held
    from customers c
    where coalesce((
      select max(b.starts_at) from bookings b where b.customer_id = c.id
    ), c.created_at) < now() - interval '8 years'
    and c.email not like 'deleted+%@deleted.local'
    and c.date_of_birth is not null
    and c.date_of_birth > (now() - interval '21 years')::date;

  -- Anonymise eligible customers
  with stale as (
    select c.id
    from customers c
    where coalesce((
      select max(b.starts_at) from bookings b where b.customer_id = c.id
    ), c.created_at) < now() - interval '8 years'
    and c.email not like 'deleted+%@deleted.local'
    -- Defer if customer was/may have been a minor and is still under 21
    and (
      c.date_of_birth is null
      or c.date_of_birth <= (now() - interval '21 years')::date
    )
  ),
  upd as (
    update customers c
      set email = 'deleted+' || c.id::text || '@deleted.local',
          first_name = 'Deleted',
          last_name = 'User',
          phone = null,
          date_of_birth = null,
          gender = null,
          address = null,
          emergency_contact_name = null,
          emergency_contact_phone = null,
          emergency_contact_relationship = null,
          notes = null,
          auth_user_id = null
      where c.id in (select id from stale)
      returning c.id
  )
  select count(*) into v_anonymised from upd;

  -- Prune audit_log entries older than 10 years (unchanged)
  delete from audit_log where occurred_at < now() - interval '10 years';
  get diagnostics v_audit_pruned = row_count;

  return jsonb_build_object(
    'ran_at', now(),
    'customers_anonymised', v_anonymised,
    'customers_held_for_minors_rule', v_minors_held,
    'audit_rows_pruned', v_audit_pruned
  );
end;
$function$;

CREATE TRIGGER audit_bookings AFTER INSERT OR DELETE OR UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION log_change();
CREATE TRIGGER audit_customers AFTER INSERT OR DELETE OR UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION log_change();
CREATE TRIGGER audit_customer_packages AFTER INSERT OR DELETE OR UPDATE ON public.customer_packages FOR EACH ROW EXECUTE FUNCTION log_change();
CREATE TRIGGER audit_customer_package_balances AFTER INSERT OR DELETE OR UPDATE ON public.customer_package_balances FOR EACH ROW EXECUTE FUNCTION log_change();
CREATE TRIGGER bookings_lead_time_check BEFORE INSERT ON public.bookings FOR EACH ROW EXECUTE FUNCTION bookings_enforce_lead_time();
CREATE TRIGGER bookings_no_overlap_check BEFORE INSERT ON public.bookings FOR EACH ROW EXECUTE FUNCTION bookings_enforce_no_overlap();
create view public.booked_slots as  SELECT starts_at,
    ends_at,
    service_id
   FROM get_booked_slots() get_booked_slots(starts_at, ends_at, service_id);
create policy "public read services" on public.services for SELECT to public using ((active = true));
create policy "public read packages" on public.packages for SELECT to public using ((active = true));
create policy "public read package contents" on public.package_contents for SELECT to public using (true);
create policy "public read availability rules" on public.availability_rules for SELECT to public using (true);
create policy "public read availability overrides" on public.availability_overrides for SELECT to public using (true);
create policy "customers cancel own bookings" on public.bookings for UPDATE to public using ((customer_id IN ( SELECT customers.id
   FROM customers
  WHERE (customers.auth_user_id = auth.uid()))));
create policy "customers read own record" on public.customers for SELECT to public using (((auth_user_id = auth.uid()) OR is_admin()));
create policy "customers insert own record" on public.customers for INSERT to public with check ((auth_user_id = auth.uid()));
create policy "customers update own record" on public.customers for UPDATE to public using (((auth_user_id = auth.uid()) OR is_admin()));
create policy "admin write package_contents" on public.package_contents for ALL to public using (is_admin()) with check (is_admin());
create policy "admin insert customers" on public.customers for INSERT to public with check (is_admin());
create policy "admin update customers all" on public.customers for UPDATE to public using (is_admin());
create policy "admin delete customers" on public.customers for DELETE to public using (is_admin());
create policy "admin insert bookings" on public.bookings for INSERT to public with check (is_admin());
create policy "admin update bookings all" on public.bookings for UPDATE to public using (is_admin());
create policy "admin delete bookings" on public.bookings for DELETE to public using (is_admin());
create policy "admin read audit_log" on public.audit_log for SELECT to public using (is_admin());
create policy "customers read own packages" on public.customer_packages for SELECT to public using (((customer_id IN ( SELECT customers.id
   FROM customers
  WHERE (customers.auth_user_id = auth.uid()))) OR is_admin()));
create policy "customers create own packages" on public.customer_packages for INSERT to public with check ((customer_id IN ( SELECT customers.id
   FROM customers
  WHERE (customers.auth_user_id = auth.uid()))));
create policy "customers read own balances" on public.customer_package_balances for SELECT to public using (((customer_package_id IN ( SELECT cp.id
   FROM (customer_packages cp
     JOIN customers c ON ((c.id = cp.customer_id)))
  WHERE (c.auth_user_id = auth.uid()))) OR is_admin()));
create policy "customers create own balances" on public.customer_package_balances for INSERT to public with check ((customer_package_id IN ( SELECT cp.id
   FROM (customer_packages cp
     JOIN customers c ON ((c.id = cp.customer_id)))
  WHERE (c.auth_user_id = auth.uid()))));
create policy "balances update own or admin" on public.customer_package_balances for UPDATE to public using (((customer_package_id IN ( SELECT cp.id
   FROM (customer_packages cp
     JOIN customers c ON ((c.id = cp.customer_id)))
  WHERE (c.auth_user_id = auth.uid()))) OR is_admin()));
create policy "customers read own bookings" on public.bookings for SELECT to public using (((customer_id IN ( SELECT customers.id
   FROM customers
  WHERE (customers.auth_user_id = auth.uid()))) OR is_admin()));
create policy "customers create own bookings" on public.bookings for INSERT to public with check ((customer_id IN ( SELECT customers.id
   FROM customers
  WHERE (customers.auth_user_id = auth.uid()))));
create policy "bookings update own or admin" on public.bookings for UPDATE to public using (((customer_id IN ( SELECT customers.id
   FROM customers
  WHERE (customers.auth_user_id = auth.uid()))) OR is_admin()));
create policy "admin write availability rules" on public.availability_rules for ALL to public using (is_admin()) with check (is_admin());
create policy "admin write availability overrides" on public.availability_overrides for ALL to public using (is_admin()) with check (is_admin());
create policy "admin write services" on public.services for ALL to public using (is_admin()) with check (is_admin());
create policy "admin write packages" on public.packages for ALL to public using (is_admin()) with check (is_admin());
create function public.rls_auto_enable() returns event_trigger language plpgsql as $$begin end$$;
alter table public.audit_log enable row level security;
alter table public.availability_overrides enable row level security;
alter table public.availability_rules enable row level security;

alter table public.bookings enable row level security;
alter table public.customer_package_balances enable row level security;
alter table public.customer_packages enable row level security;
alter table public.customers enable row level security;
alter table public.package_contents enable row level security;
alter table public.packages enable row level security;
alter table public.services enable row level security;
grant usage on schema public,auth to anon,authenticated,service_role; grant all on all tables in schema public to anon,authenticated,service_role; grant usage on all sequences in schema public to anon,authenticated,service_role;