-- Revision 29. Non-destructive performance improvements for existing policies.
-- The predicates and roles remain identical; only stable auth lookups are
-- evaluated once per statement. Existing RLS stays enabled.
begin;

create index if not exists kp_admin_audit_actor_idx on public.kp_admin_audit(actor_id);
create index if not exists kp_media_owner_idx on public.kp_media(owner_id);
create index if not exists kp_media_recipient_idx on public.kp_media(recipient_id);
create index if not exists kp_messages_media_idx on public.kp_messages(media_id);
create index if not exists kp_operations_actor_idx on public.kp_operations(actor_id);
create index if not exists kp_push_events_sender_idx on public.kp_push_events(sender);
create index if not exists kp_roles_granted_by_idx on public.kp_roles(granted_by);
create index if not exists kp_taxi_orders_abandoned_by_idx on public.kp_taxi_orders(abandoned_by);
create index if not exists kp_v8_bets_event_idx on public.kp_v8_bets(event_id);

alter policy kp_roles_read on public.kp_roles
  using (user_id = (select auth.uid()) or (select public.kp_has_role('owner')));
alter policy kp_wallets_read on public.kp_wallets
  using (user_id = (select auth.uid()) or (select public.kp_has_role('owner')));
alter policy kp_ledger_read on public.kp_ledger
  using (user_id = (select auth.uid()) or (select public.kp_has_role('owner')));
alter policy kp_operations_read on public.kp_operations
  using (actor_id = (select auth.uid()));
alter policy kp_notifications_read on public.kp_notifications
  using (user_id = (select auth.uid()));
alter policy kp_notifications_mark_read on public.kp_notifications
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
alter policy kp_taxi_orders_read on public.kp_taxi_orders
  using (
    client_id = (select auth.uid()) or
    driver_id = (select auth.uid()) or
    (status = 'pending' and (select public.kp_has_role('driver'))) or
    (select public.kp_has_role('owner'))
  );
alter policy kp_debts_read on public.kp_treasury_debts
  using (user_id = (select auth.uid()) or (select public.kp_has_role('owner')));
alter policy kp_messages_read on public.kp_messages
  using (room = 'general' or sender_id = (select auth.uid()) or recipient_id = (select auth.uid()));
alter policy kp_media_read on public.kp_media
  using (recipient_id is null or owner_id = (select auth.uid()) or recipient_id = (select auth.uid()));

commit;
