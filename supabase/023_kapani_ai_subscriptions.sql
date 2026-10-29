-- Separate KapaniGPT subscriptions. Apply after 001–022 in Supabase SQL Editor.
-- All prices are fictional Kapani rubles, deducted only by this server-side RPC.
begin;

create table if not exists public.kp_ai_subscription_ops (
  id uuid primary key,
  actor text not null,
  plan text not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.kp_ai_subscription_ops enable row level security;
revoke all on public.kp_ai_subscription_ops from public, anon, authenticated;

create or replace function public.kp_ai_status()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  a text := public.kp_v8_actor();
  person jsonb;
  expires timestamptz;
  active_plan text;
begin
  if a is null then raise exception 'Sign in to Kapani first'; end if;
  select document->a into person from public.kp_tree_roots where branch='users';
  if person is null then raise exception 'Kapani account not found'; end if;
  if coalesce(person->>'aiSubscriptionExpiry','') ~ '^20[0-9]{2}-' then
    begin expires := (person->>'aiSubscriptionExpiry')::timestamptz;
    exception when others then expires := null; end;
  end if;
  active_plan := case when expires > now() and person->>'aiSubscription' in ('plus','ultra','prime')
    then person->>'aiSubscription' else 'free' end;
  return jsonb_build_object('plan', active_plan, 'expiresAt', expires,
    'balance', coalesce(nullif(person->>'balance','')::bigint, 0),
    'nickname', a);
end;
$$;

create or replace function public.kp_ai_buy(p_plan text, p_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  a text := public.kp_v8_actor();
  person jsonb;
  users jsonb;
  prior public.kp_ai_subscription_ops%rowtype;
  price bigint;
  balance_after bigint;
  expiry timestamptz;
  old_expiry timestamptz;
  result jsonb;
  plan_label text;
begin
  if a is null or p_id is null then raise exception 'Sign in to Kapani first'; end if;
  price := case p_plan when 'plus' then 499 when 'ultra' then 1299 when 'prime' then 2999 else null end;
  if price is null then raise exception 'Unknown Kapani AI plan'; end if;

  -- Serialize purchases with wallet mutations and make retries idempotent.
  select document into users from public.kp_tree_roots where branch='users' for update;
  person := users->a;
  if person is null or coalesce(person->>'accountVerified','false') <> 'true'
    or person->>'accountFrozen' = 'true' then
    raise exception 'Verified active Kapani account required';
  end if;
  select * into prior from public.kp_ai_subscription_ops where id=p_id;
  if found then
    if prior.actor <> a or prior.plan <> p_plan then raise exception 'Purchase retry mismatch'; end if;
    return prior.result;
  end if;
  if coalesce(person->>'aiSubscriptionExpiry','') ~ '^20[0-9]{2}-' then
    begin old_expiry := (person->>'aiSubscriptionExpiry')::timestamptz;
    exception when others then old_expiry := null; end;
  end if;
  expiry := case when old_expiry > now() and person->>'aiSubscription' = p_plan
    then old_expiry + interval '7 days' else now() + interval '7 days' end;

  balance_after := public.kp_v8_money(a, -price, p_id, 'kapani_ai_subscription',
    jsonb_build_object('plan',p_plan,'period','7 days'));
  -- kp_v8_money updated the authoritative wallet; re-read the whole root.
  select document into users from public.kp_tree_roots where branch='users';
  person := users->a || jsonb_build_object(
    'aiSubscription',p_plan,
    'aiSubscriptionExpiry',to_char(expiry at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
  perform public.kp_v8_put('users',jsonb_set(users,array[a],person));

  result := jsonb_build_object('success',true,'plan',p_plan,'price',price,
    'balance',balance_after,'expiresAt',expiry,'transactionId',p_id);
  insert into public.kp_ai_subscription_ops(id,actor,plan,result)
    values(p_id,a,p_plan,result);

  plan_label := case p_plan when 'plus' then 'Kapani AI plus' when 'ultra' then 'Kapani AI ultra'
    else 'Kapani AI prime' end;
  -- The existing Kapani listener shows this as an in-site/background notification.
  perform public.kp_v8_notify(a,
    plan_label || ' оплачена. Списано ' || price || ' капанёвских ₽. Остаток ' ||
    balance_after || ' капанёвских ₽.', 'system','kapani_ai_' || p_id::text);
  return result;
end;
$$;

revoke all on function public.kp_ai_status(), public.kp_ai_buy(text,uuid) from public, anon, authenticated;
grant execute on function public.kp_ai_status(), public.kp_ai_buy(text,uuid) to authenticated;
commit;
