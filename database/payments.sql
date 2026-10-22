-- Private payment state keeps intake data out of Stripe and records recovery work.
create table public.pending_checkouts (
 id uuid primary key default gen_random_uuid(), kind text not null check(kind in ('booking','package')),
 payload jsonb not null, expected_amount integer not null check(expected_amount>0),
 stripe_session_id text unique, payment_intent text, created_at timestamptz not null default now(),
 status text not null default 'pending' check(status in ('pending','completed','refund_required','refunded')),
 booking_id uuid references public.bookings(id), customer_package_id uuid references public.customer_packages(id),
 failure_reason text, refund_id text
);
alter table public.pending_checkouts enable row level security;
revoke all on public.pending_checkouts from anon,authenticated;
grant all on public.pending_checkouts to service_role;
create unique index customer_packages_stripe_unique on public.customer_packages(stripe_payment_id) where stripe_payment_id is not null;

create or replace function public.activate_package(p_customer_id uuid,p_package_id uuid,p_session_id text,p_amount integer)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid; p packages%rowtype;
begin
 perform pg_advisory_xact_lock(20371022);
 select id into v_id from customer_packages where stripe_payment_id=p_session_id;
 if found then return v_id; end if;
 select * into p from packages where id=p_package_id;
 if not found or p_amount<>p.price_pence then raise exception 'Package payment does not match'; end if;
 if not exists(select 1 from package_contents where package_id=p.id) then raise exception 'Package has no sessions configured'; end if;
 insert into customer_packages(customer_id,package_id,expires_at,amount_paid_pence,stripe_payment_id)
 values(p_customer_id,p.id,now()+make_interval(days=>p.expiry_days),p_amount,p_session_id) returning id into v_id;
 insert into customer_package_balances(customer_package_id,service_id,sessions_remaining)
 select v_id,service_id,quantity from package_contents where package_id=p.id;
 return v_id;
end $$;
revoke all on function public.activate_package(uuid,uuid,text,integer) from public,anon,authenticated;
grant execute on function public.activate_package(uuid,uuid,text,integer) to service_role;

create function public.stage_checkout(p_kind text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare amount integer; v_id uuid;
begin
 if p_kind='booking' then
   perform validate_booking_slot((p_payload->>'service_id')::uuid,(p_payload->>'starts_at')::timestamptz,(p_payload->>'ends_at')::timestamptz);
   if nullif(trim(p_payload->>'email'),'') is null then raise exception 'Email is required'; end if;
   select price_pence into amount from services where id=(p_payload->>'service_id')::uuid and active;
 elsif p_kind='package' then
   select price_pence into amount from packages where id=(p_payload->>'package_id')::uuid and active;
 else raise exception 'Invalid checkout type'; end if;
 if amount is null then raise exception 'Item is unavailable'; end if;
 insert into pending_checkouts(kind,payload,expected_amount) values(p_kind,p_payload,amount) returning id into v_id;
 return jsonb_build_object('id',v_id,'amount',amount);
end $$;
revoke all on function public.stage_checkout(text,jsonb) from public,anon,authenticated;
grant execute on function public.stage_checkout(text,jsonb) to service_role;

create function public.complete_checkout(p_id uuid,p_session text,p_payment_intent text,p_amount integer,p_currency text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare c pending_checkouts%rowtype; b jsonb; v_id uuid; failure text;
begin
 perform pg_advisory_xact_lock(20371022);
 select * into c from pending_checkouts where id=p_id for update;
 if not found then raise exception 'Checkout record is missing'; end if;
 if c.stripe_session_id is not null and c.stripe_session_id<>p_session then raise exception 'Checkout session mismatch'; end if;
 if c.status<>'pending' then return jsonb_build_object('status',c.status,'booking_id',c.booking_id,'customer_package_id',c.customer_package_id); end if;
 update pending_checkouts set stripe_session_id=p_session,payment_intent=p_payment_intent where id=c.id;
 if c.expected_amount is distinct from p_amount or p_currency is distinct from 'gbp' then
   update pending_checkouts set status='refund_required',failure_reason='Payment amount or currency mismatch' where id=c.id;
   return jsonb_build_object('status','refund_required');
 end if;
 begin
   b:=c.payload;
   if c.kind='booking' then
     -- Lead time was checked before payment. Opening hours and capacity are checked again now.
     perform set_config('app.paid_checkout','true',true);
     v_id:=create_anonymous_booking(
       p_email=>b->>'email',p_first_name=>b->>'first_name',p_last_name=>b->>'last_name',p_phone=>b->>'phone',
       p_date_of_birth=>nullif(b->>'date_of_birth','')::date,p_gender=>b->>'gender',p_address=>b->>'address',
       p_emergency_contact_name=>b->>'emergency_contact_name',p_emergency_contact_phone=>b->>'emergency_contact_phone',
       p_emergency_contact_relationship=>b->>'emergency_contact_relationship',p_service_id=>(b->>'service_id')::uuid,
       p_starts_at=>(b->>'starts_at')::timestamptz,p_ends_at=>(b->>'ends_at')::timestamptz,
       p_intake_response=>jsonb_build_object('reason',b->>'reason','medications',b->>'medications','conditions',b->>'conditions'),
       p_electro_acupuncture_consent=>coalesce((b->>'electro_consent')::boolean,false),
       p_general_consent_version=>b->>'general_consent_version',p_notes=>'stripe:'||p_session);
     perform set_config('app.paid_checkout','false',true);
     update pending_checkouts set booking_id=v_id,status='completed',payload='{}'::jsonb where id=c.id;
   else
     v_id:=activate_package((b->>'customer_id')::uuid,(b->>'package_id')::uuid,p_session,p_amount);
     update pending_checkouts set customer_package_id=v_id,status='completed',payload='{}'::jsonb where id=c.id;
   end if;
 exception when raise_exception then
   get stacked diagnostics failure=message_text;
   update pending_checkouts set status='refund_required',failure_reason=failure where id=c.id;
   return jsonb_build_object('status','refund_required');
 end;
 return jsonb_build_object('status','completed');
end $$;
revoke all on function public.complete_checkout(uuid,text,text,integer,text) from public,anon,authenticated;
grant execute on function public.complete_checkout(uuid,text,text,integer,text) to service_role;

create function public.checkout_status(p_id uuid) returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
 select jsonb_build_object('status',status,'kind',kind) from pending_checkouts where id=p_id
$$;
revoke all on function public.checkout_status(uuid) from public;
grant execute on function public.checkout_status(uuid) to anon,authenticated,service_role;
