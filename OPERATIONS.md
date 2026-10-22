# Booking platform operations

The public booking and admin pages are served by Vercel at https://book.ednicholls.com. Squarespace embeds that URL; updating this repository and deploying the Vercel project updates the embedded booking page too. The rest of the Squarespace site is separate.

## Booking rules

All appointment times are Europe/London, including daylight-saving changes. Thursday multi-bed starts are 18:00–20:15, every 15 minutes, with 45-minute appointments, one new arrival per start and at most three concurrent appointments. Opening hours, closures, duration, slot alignment and capacity are checked in PostgreSQL, not just the page. Private appointment notice comes from services.min_lead_hours. Admin walk-ins bypass the notice period, but not capacity or opening hours.

A package must be active and unexpired when redeemed. The appointment may occur after expiry. Cancellation returns a package credit once, whether the patient or administrator cancels. Cancelling a paid single appointment does not automatically issue a card refund; Ed handles that explicitly. Cancelling an expired-package appointment does not extend its expiry.

## Payments and email

New Stripe checkouts carry only a checkout reference and type in metadata. Contact email is supplied for the payment receipt; intake stays in the protected pending_checkouts table and is moved into the booking on fulfilment. A successful redirect is not proof of a confirmed booking: the page polls the recorded outcome.

Opening payment does not reserve a slot. Capacity is checked again when Stripe confirms payment. If the slot cannot be honoured, a refund is requested with an idempotency key. Transient infrastructure failures return a retryable response to Stripe. Unresolved fulfilments and refunds are visible in the admin attention panel. A refund still pending at Stripe is not labelled complete.

Notification jobs are created transactionally, claimed with a lease, and sent with a stable Resend idempotency key. Failed delivery retries automatically; retries stop before Resend's 24-hour idempotency window expires. The admin panel shows delayed or failed jobs. A five-minute Supabase cron job wakes the worker. All three email endpoints require the database-generated internal token. Do not publish or export that token. Reminder wording uses the actual appointment date rather than assuming tomorrow.

A job marked sent means Resend accepted it, not necessarily that the recipient's mailbox delivered it. Check Resend for delivery/bounce events before manually resending. Never blindly reset a sent or ambiguous job, which could duplicate an email.

## Account closure and retention

Account closure cancels future confirmed bookings, removes customer contact identifiers, queues deletion of the Supabase Auth user through its supported admin API, and removes personal details from that customer's historical audit entries. The worker retries failed authentication deletion. New audit entries record actions and row identifiers without copies of clinical/contact fields. The existing clinical retention policy needs practice review; account closure is not a promise to erase all clinical information immediately. A retention deadline is preserved before date of birth is removed. Existing clinical/audit retention jobs are not a legal compliance guarantee.

The account export includes bookings, intake, clinical journal, packages and balances. Clinical records may contain contextual information that requires review for a formal subject access request.

## Deployment

1. Run `pnpm install --frozen-lockfile` and `pnpm test` with Node 24. Syntax-check inline scripts in both HTML files and build with `node scripts/build.mjs`.
2. Capture and verify an encrypted application export before database changes.
3. Apply reviewed SQL in order: booking-integrity, payments, notifications, account-privacy. These are the initial upgrade scripts; use new migrations for subsequent changes rather than rerunning create-table statements.
4. Deploy create-checkout-session, stripe-webhook, and the three notification functions, including their _shared dependencies. JWT gateway validation is disabled because the handlers enforce Stripe signatures, user authentication where needed, or the internal token themselves.
5. Apply schedule-notifications after the worker is live.
6. Test a Vercel preview, then deploy the verified commit to production. Only dist is served; database, tests and function sources are excluded from the web output.
7. Verify live slots, unauthorized API rejection, delivery queue status, and Supabase advisors. Avoid creating real patient appointments or charges as smoke tests.

## Encrypted exports and recovery

Supabase's free plan does not include the daily backups claimed by the old handover. Source: https://supabase.com/docs/guides/platform/backups

The local export process captures application tables, schema metadata and Auth ID/email mappings, then encrypts with AES-256-GCM and an RSA-OAEP-wrapped key. The private recovery key is outside the repository, at /Users/ed/Documents/Codex/booking-backups/recovery-key.pem. Keep a separate secure copy of the recovery key and encrypted exports. A copy only on this Mac does not protect against loss of the Mac.

This is an application export, not a provider-level database snapshot. It excludes authentication passwords, sessions, provider secrets, storage objects and internal notification tokens. Restoring to another Supabase project requires recreating/relinking Auth accounts, re-entering provider secrets and regenerating the notification token. Never restore production without reviewing newer bookings and payments made after the export.

`node scripts/verify-backup.mjs <encrypted-file> <recovery-key>` decrypts in memory and imports the application records into an isolated local PostgreSQL engine to verify row counts without printing patient data. The SQL export is scripts/export-booking.sql. Scheduled exports depend on this Mac and Codex being available with the connector authenticated; failure must be surfaced, not reported as a successful backup.

## Verification limits

Automated checks cover slot rules, London clock changes, package expiry, credit permissions, collision privacy, atomic payment activation, duplicate fulfilment, cancellation, account closure, queue claiming, Stripe signatures, clinical metadata exclusion and retry responses. PGlite tests are single-engine tests, not a multi-connection load test. Stripe API calls are mocked; no real card charge is needed for this release. Future changes should retain these checks and add a Stripe test-mode end-to-end environment before major payment changes.
