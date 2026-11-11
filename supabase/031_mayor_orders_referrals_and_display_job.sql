-- Secure mayor order removal, advertiser reporting and self-selected job title.
begin;

create table if not exists public.kp_mayor_order_archive (
  id text primary key,
  original jsonb not null,
  removed_by text not null,
  removed_at timestamptz not null default now()
);
alter table public.kp_mayor_order_archive enable row level security;
revoke all on public.kp_mayor_order_archive from public, anon, authenticated;

create or replace function public.kp_mayor_delete_order_v31(p_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor text:=public.kp_v8_actor();
  orders_doc jsonb;
  order_doc jsonb;
  users_doc jsonb;
  customer text;
  refund_amount bigint;
  refund_id uuid;
begin
  if actor is distinct from 'Кайон' then raise exception 'Mayor access required'; end if;
  if p_id is null or length(p_id) not between 1 and 140 or p_id ~ '[[:cntrl:]]' then
    raise exception 'Invalid order ID';
  end if;
  select document into orders_doc from public.kp_tree_roots where branch='orders' for update;
  order_doc:=orders_doc->p_id;
  if order_doc is null then raise exception 'Order not found or already removed'; end if;
  customer:=order_doc->>'client';
  refund_amount:=coalesce((order_doc->>'escrowAmount')::bigint,0);
  if refund_amount<0 or refund_amount>1000000000 then raise exception 'Invalid escrow amount'; end if;
  if refund_amount>0 then
    if customer is null or not exists(select 1 from public.kp_profiles where nickname=customer)
      then raise exception 'Refund recipient missing; contact support before removing this order'; end if;
    refund_id:=(md5('mayor_delete_order:'||p_id||':refund'))::uuid;
    perform public.kp_v8_money(customer,refund_amount,refund_id,'service_refund',
      jsonb_build_object('order',p_id,'source','mayor_delete'));
  end if;
  insert into public.kp_mayor_order_archive(id,original,removed_by)
    values(p_id,order_doc,actor) on conflict(id) do update
    set original=excluded.original,removed_by=excluded.removed_by,removed_at=now();
  perform public.kp_v8_put('orders',orders_doc-p_id);
  select document into users_doc from public.kp_tree_roots where branch='users';
  if customer is not null and users_doc ? customer then
    perform public.kp_v8_notify(customer,
      case when refund_amount>0 then 'Мэрия удалила заказ. Оплата возвращена.'
        else 'Мэрия удалила заказ.' end,'system','mayor_delete_order_'||p_id);
  end if;
  return jsonb_build_object('ok',true,'removed',p_id,'refunded',refund_amount);
end;
$$;
revoke all on function public.kp_mayor_delete_order_v31(text) from public,anon,authenticated;
grant execute on function public.kp_mayor_delete_order_v31(text) to authenticated;

create or replace function public.kp_set_display_job_v31(p_role text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor text:=public.kp_v8_actor();
  users_doc jsonb;
  resident jsonb;
  jobs jsonb;
  valid_job boolean;
begin
  if actor is null then raise exception 'Authentication required'; end if;
  if p_role is null or length(trim(p_role)) not between 1 and 100 then
    raise exception 'Choose an active job'; end if;
  select document into users_doc from public.kp_tree_roots where branch='users' for update;
  resident:=users_doc->actor;
  if resident is null then raise exception 'Profile not found'; end if;
  jobs:=case jsonb_typeof(resident->'employments')
    when 'array' then resident->'employments'
    when 'object' then coalesce((select jsonb_agg(value) from jsonb_each(resident->'employments')),'[]'::jsonb)
    else '[]'::jsonb end;
  valid_job:=exists(select 1 from jsonb_array_elements(jobs) e
    where e->>'role'=p_role and nullif(e->>'id','') is not null)
    or (resident->>'job'=p_role and p_role<>'Житель');
  if not valid_job then raise exception 'You do not have this active job'; end if;
  resident:=jsonb_set(resident,'{displayJob}',to_jsonb(p_role),true);
  perform public.kp_v8_put('users',jsonb_set(users_doc,array[actor],resident,true));
  return jsonb_build_object('ok',true,'displayJob',p_role);
end;
$$;
revoke all on function public.kp_set_display_job_v31(text) from public,anon,authenticated;
grant execute on function public.kp_set_display_job_v31(text) to authenticated;

create or replace function public.kp_referral_summary(p_target text default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor text:=public.kp_v8_actor(); users_doc jsonb; stats_doc jsonb;
  target text; count_for_target bigint; result jsonb:='[]'::jsonb;
  advertiser record; reset_ms bigint;
begin
  if actor is null then raise exception 'Authentication required'; end if;
  target:=coalesce(p_target,actor);
  if target<>actor and actor<>'Кайон' then raise exception 'Private referral stats'; end if;
  select document into users_doc from public.kp_tree_roots where branch='users';
  select document into stats_doc from public.kp_tree_roots where branch='advertiserStats';
  if p_target is not null then
    reset_ms:=coalesce((stats_doc->target->>'resetAt')::bigint,0);
    select count(*) into count_for_target from jsonb_each(coalesce(users_doc,'{}'::jsonb)) u
      where u.value->>'invitedBy'=target
        and exists(select 1 from public.kp_profiles p where p.nickname=u.key)
        and coalesce((u.value->>'referralCreatedAt')::bigint,(u.value->>'createdAt')::bigint,0)>reset_ms;
    return jsonb_build_object('count',count_for_target);
  end if;
  if actor<>'Кайон' then raise exception 'Mayor access required'; end if;
  for advertiser in select key,value from jsonb_each(coalesce(users_doc,'{}'::jsonb)) loop
    if public.kp_v8_role(advertiser.key,'Рекламщик') then
      reset_ms:=coalesce((stats_doc->(advertiser.key)->>'resetAt')::bigint,0);
      select count(*) into count_for_target from jsonb_each(coalesce(users_doc,'{}'::jsonb)) u
        where u.value->>'invitedBy'=advertiser.key
          and exists(select 1 from public.kp_profiles p where p.nickname=u.key)
          and coalesce((u.value->>'referralCreatedAt')::bigint,(u.value->>'createdAt')::bigint,0)>reset_ms;
      result:=result||jsonb_build_array(jsonb_build_object('nick',
        coalesce(nullif(advertiser.value->>'displayName',''),advertiser.key),
        'count',count_for_target));
    end if;
  end loop;
  return result;
end;
$$;
revoke all on function public.kp_referral_summary(text) from public,anon,authenticated;
grant execute on function public.kp_referral_summary(text) to authenticated;

create or replace function public.kp_mayor_clear_referrals()
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor text:=public.kp_v8_actor(); users_doc jsonb; stats_doc jsonb;
  advertiser record; count_cleared integer:=0; reset_ms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
  if actor is distinct from 'Кайон' then raise exception 'Mayor access required'; end if;
  select document into users_doc from public.kp_tree_roots where branch='users';
  insert into public.kp_tree_roots(branch) values('advertiserStats') on conflict do nothing;
  select document into stats_doc from public.kp_tree_roots where branch='advertiserStats' for update;
  for advertiser in select key,value from jsonb_each(coalesce(users_doc,'{}'::jsonb)) loop
    if public.kp_v8_role(advertiser.key,'Рекламщик') then
      stats_doc:=jsonb_set(coalesce(stats_doc,'{}'::jsonb),array[advertiser.key],
        jsonb_build_object('resetAt',reset_ms,'updatedAt',reset_ms),true);
      count_cleared:=count_cleared+1;
    end if;
  end loop;
  perform public.kp_v8_put('advertiserStats',stats_doc);
  return jsonb_build_object('ok',true,'cleared',count_cleared);
end;
$$;
revoke all on function public.kp_mayor_clear_referrals() from public,anon,authenticated;
grant execute on function public.kp_mayor_clear_referrals() to authenticated;

-- A registration worker can complete account creation even when its older
-- bootstrap discarded the inviter. The signed-in new resident gets a single
-- short-lived chance to restore that original referral; never overwrite one.
create or replace function public.kp_claim_signup_referrer_v31(p_inviter text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor text:=public.kp_v8_actor();
  users_doc jsonb;
  resident jsonb;
  advertiser jsonb;
  created_ms bigint;
  now_ms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
  if actor is null then raise exception 'Authentication required'; end if;
  if p_inviter is null or length(p_inviter) not between 3 and 30 or p_inviter=actor then
    raise exception 'Invalid inviter'; end if;
  select document into users_doc from public.kp_tree_roots where branch='users' for update;
  resident:=users_doc->actor;
  advertiser:=users_doc->p_inviter;
  if resident is null or advertiser is null
     or not exists(select 1 from public.kp_profiles where nickname=p_inviter)
     or not public.kp_v8_role(p_inviter,'Рекламщик') then
    raise exception 'Inviter is not an active advertiser'; end if;
  if resident->>'invitedBy'=p_inviter then return jsonb_build_object('ok',true,'alreadySaved',true); end if;
  if resident ? 'invitedBy' then raise exception 'Referrer has already been recorded'; end if;
  created_ms:=coalesce((resident->>'createdAt')::bigint,0);
  if created_ms=0 or created_ms>now_ms+60000 or now_ms-created_ms>259200000 then
    raise exception 'Registration referral period has expired'; end if;
  resident:=resident||jsonb_build_object(
    'invitedBy',p_inviter,
    'invitedByName',coalesce(nullif(advertiser->>'displayName',''),p_inviter),
    'referralCreatedAt',created_ms,
    'referralWeekKey',to_char(to_timestamp(created_ms/1000.0) at time zone 'Europe/Moscow','IYYY-"W"IW')
  );
  perform public.kp_v8_put('users',jsonb_set(users_doc,array[actor],resident,true));
  return jsonb_build_object('ok',true,'invitedBy',p_inviter);
end;
$$;
revoke all on function public.kp_claim_signup_referrer_v31(text) from public,anon,authenticated;
grant execute on function public.kp_claim_signup_referrer_v31(text) to authenticated;

commit;
