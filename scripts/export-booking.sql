select jsonb_build_object('format_version',1,'exported_at',now(),'project_ref','bdzasnbzyfkqojqqucil','data',jsonb_build_object(
'services',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.services t),
'packages',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.packages t),
'package_contents',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.package_contents t),
'customers',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.customers t),
'customer_packages',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.customer_packages t),
'customer_package_balances',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.customer_package_balances t),
'bookings',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.bookings t),
'availability_rules',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.availability_rules t),
'availability_overrides',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.availability_overrides t),
'pending_checkouts',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.pending_checkouts t),
'notification_jobs',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.notification_jobs t),
'account_deletion_requests',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.account_deletion_requests t),
'audit_log',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.audit_log t)),
'auth_mapping',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'email',email,'email_confirmed_at',email_confirmed_at)),'[]'::jsonb) from auth.users),
'schema',jsonb_build_object(
'columns',(select jsonb_agg(to_jsonb(c)) from information_schema.columns c where table_schema='public'),
'functions',(select jsonb_agg(jsonb_build_object('name',p.proname,'definition',pg_get_functiondef(p.oid),'acl',p.proacl)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f'),
'policies',(select jsonb_agg(to_jsonb(p)) from pg_policies p where schemaname='public'),
'triggers',(select jsonb_agg(pg_get_triggerdef(t.oid)) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal),
'constraints',(select jsonb_agg(jsonb_build_object('table',c.relname,'name',x.conname,'definition',pg_get_constraintdef(x.oid))) from pg_constraint x join pg_class c on c.oid=x.conrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'),
'indexes',(select jsonb_agg(to_jsonb(i)) from pg_indexes i where schemaname='public')
)) as backup;
