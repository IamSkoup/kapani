-- Apply after 012. Alert drivers in the same transaction that publishes a
-- waiting taxi order, including when an assigned driver returns an order.
begin;
create or replace function public.kp_taxi_waiting_alert_v27()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  order_entry record;
  resident record;
  users_doc jsonb;
  previous_doc jsonb;
  event_key text;
begin
  if new.branch <> 'orders' then return new; end if;
  if tg_op='INSERT' then previous_doc:='{}'::jsonb;
  else previous_doc:=old.document; end if;
  select document into users_doc from public.kp_tree_roots where branch='users' for update;
  for order_entry in select key,value from jsonb_each(new.document) loop
    if order_entry.value->>'type' <> 'taxi'
       or order_entry.value->>'status' <> 'pending'
       or order_entry.value->>'worker' is not null
       or (previous_doc->order_entry.key->>'status' = 'pending'
           and previous_doc->order_entry.key->>'worker' is null) then
      continue;
    end if;
    event_key:='taxi_'||order_entry.key||'_waiting_'
      ||coalesce(order_entry.value->>'updatedAt','0');
    for resident in select key,value from jsonb_each(coalesce(users_doc,'{}'::jsonb)) loop
      if resident.key <> order_entry.value->>'client' and (
        resident.value->>'job'='Водитель'
        or exists (select 1 from jsonb_array_elements(
          case when jsonb_typeof(resident.value->'employments')='array'
            then resident.value->'employments' else '[]'::jsonb end) as employment(job)
          where job->>'type'='municipal' and job->>'role'='Водитель')
      ) then
        perform public.kp_v8_notify(resident.key,
          'Новый заказ такси: '||left(coalesce(order_entry.value->>'info','поездка по карте'),350),
          'taxi_orders',event_key);
      end if;
    end loop;
  end loop;
  return new;
end;
$$;
revoke all on function public.kp_taxi_waiting_alert_v27() from public,anon,authenticated;
drop trigger if exists kp_taxi_waiting_alert_v27 on public.kp_tree_roots;
create trigger kp_taxi_waiting_alert_v27 after update of document on public.kp_tree_roots
for each row when (new.branch='orders') execute function public.kp_taxi_waiting_alert_v27();
drop trigger if exists kp_taxi_waiting_alert_insert_v27 on public.kp_tree_roots;
create trigger kp_taxi_waiting_alert_insert_v27 after insert on public.kp_tree_roots
for each row when (new.branch='orders') execute function public.kp_taxi_waiting_alert_v27();
commit;
