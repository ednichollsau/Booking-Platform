-- Run after deploying the authenticated notification worker.
select cron.schedule('send-booking-reminders','*/5 * * * *','select public.wake_notification_worker();');
