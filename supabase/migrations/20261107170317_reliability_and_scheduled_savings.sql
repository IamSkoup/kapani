begin;
-- Apply after 018 (and any later migrations already installed).
-- Savings interest is recorded in kp_ledger with account='savings'.
-- Preserve the existing account check and add that one account type.


do $$
declare
  rule text;
  expression text;
begin
  select pg_get_constraintdef(c.oid) into rule
  from pg_constraint c
  where c.conrelid='public.kp_ledger'::regclass
    and c.conname='kp_ledger_account_check'
    and c.contype='c';

  if rule is null then
    raise exception 'kp_ledger_account_check not found; inspect the ledger schema before applying 024';
  end if;
  if rule ~ '''savings''' then return; end if;
  expression := (regexp_match(rule, '^CHECK \((.*)\)$'))[1];
  if expression is null or expression !~ '\maccount\M' then
    raise exception 'Unexpected kp_ledger_account_check: %', rule;
  end if;

  alter table public.kp_ledger drop constraint kp_ledger_account_check;
  execute format(
    'alter table public.kp_ledger add constraint kp_ledger_account_check check ((%s) or account = %L)',
    expression, 'savings'
  );
end;
$$;



CREATE OR REPLACE FUNCTION public.kp_bank_transfer(p_recipient text, p_amount bigint, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  sender text; recipient_uid uuid; sender_doc jsonb; recipient_doc jsonb;
  root_doc jsonb; treasury jsonb; rev bigint; treasury_rev bigint;
  sender_balance bigint; recipient_balance bigint; rate numeric; fee bigint; total bigint;
  sender_prime boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select nickname into sender from public.kp_profiles where user_id=auth.uid();
  select user_id into recipient_uid from public.kp_profiles where nickname=p_recipient;
  if sender is null or recipient_uid is null or recipient_uid=auth.uid() then
    raise exception 'Invalid recipient';
  end if;
  if p_request_id is null or p_amount is null or p_amount<=0 or p_amount>1000000 then
    raise exception 'Invalid amount';
  end if;
  insert into public.kp_tree_roots(branch) values('users') on conflict do nothing;
  insert into public.kp_tree_roots(branch) values('municipalTreasury') on conflict do nothing;
  select document,revision into root_doc,rev from public.kp_tree_roots where branch='users' for update;
  sender_doc:=root_doc->sender; recipient_doc:=root_doc->p_recipient;
  if sender_doc is null or recipient_doc is null then raise exception 'Account missing'; end if;
  if coalesce(sender_doc->>'accountVerified','false')<>'true'
    or coalesce(recipient_doc->>'accountVerified','false')<>'true' then
    raise exception 'Both accounts must be verified';
  end if;
  if coalesce(sender_doc->'roles'->>'migrant','false')='true'
    or coalesce(recipient_doc->'roles'->>'migrant','false')='true' then
    raise exception 'Transfers disabled for migrant accounts';
  end if;
  if coalesce(sender_doc->>'accountFrozen','false')='true' then
    raise exception 'Account is frozen';
  end if;
  -- Lock both wallets in a deterministic order.
  perform 1 from public.kp_wallets
    where user_id in (auth.uid(),recipient_uid) order by user_id for update;
  select balance into sender_balance from public.kp_wallets where user_id=auth.uid();
  select balance into recipient_balance from public.kp_wallets where user_id=recipient_uid;
  if sender_balance is null or recipient_balance is null then raise exception 'Wallet missing'; end if;
  if exists(select 1 from public.kp_ledger where operation_id=p_request_id) then
    if not exists(select 1 from public.kp_ledger where operation_id=p_request_id
      and user_id=auth.uid() and kind='bank_transfer' and account='wallet'
      and details->>'to'=p_recipient and -amount-coalesce((details->>'fee')::bigint,0)=p_amount) then
      raise exception 'Operation identifier conflicts with another request';
    end if;
    return (select jsonb_build_object('success',true,'repeated',true,'commissionCharged',true,
      'commission',coalesce((details->>'fee')::bigint,0),'balance',sender_balance)
      from public.kp_ledger where operation_id=p_request_id and user_id=auth.uid()
      and kind='bank_transfer' and account='wallet' limit 1);
  end if;
  sender_prime:=sender_doc->>'subscription'='prime' and
    coalesce((sender_doc->>'subscriptionExpiry')::timestamptz,now()-interval '1 day')>now();
  rate:=case when sender_prime then 0.01 else 0.02 end;
  fee:=greatest(1,round(p_amount*rate)::bigint); total:=p_amount+fee;
  if sender_balance<total then raise exception 'Insufficient funds including fee'; end if;
  if recipient_balance+p_amount>1000000000 then raise exception 'Recipient balance limit'; end if;
  update public.kp_wallets set balance=balance-total,updated_at=now() where user_id=auth.uid();
  update public.kp_wallets set balance=balance+p_amount,updated_at=now() where user_id=recipient_uid;
  -- One ledger row per unique operation_id. The recipient's entry uses a
  -- deterministic second UUID so repeating the request remains idempotent.
  insert into public.kp_ledger(operation_id,user_id,account,amount,kind,details) values
    (p_request_id,auth.uid(),'wallet',-total,'bank_transfer',jsonb_build_object('to',p_recipient,'fee',fee)),
    ((md5(p_request_id::text||':recipient'))::uuid,recipient_uid,'wallet',p_amount,
      'bank_transfer',jsonb_build_object('from',sender,'transferId',p_request_id));
  root_doc:=jsonb_set(root_doc,array[sender,'balance'],to_jsonb(sender_balance-total),true);
  root_doc:=jsonb_set(root_doc,array[p_recipient,'balance'],to_jsonb(recipient_balance+p_amount),true);
  update public.kp_tree_roots set document=root_doc,revision=rev+1,updated_at=now() where branch='users';
  insert into public.kp_tree_revisions(branch,revision) values('users',rev+1)
    on conflict(branch) do update set revision=excluded.revision;
  if fee>0 then
    select document,revision into treasury,treasury_rev from public.kp_tree_roots
      where branch='municipalTreasury' for update;
    treasury:=jsonb_set(treasury,'{balance}',
      to_jsonb(coalesce((treasury->>'balance')::bigint,0)+fee),true);
    update public.kp_tree_roots set document=treasury,revision=treasury_rev+1,updated_at=now()
      where branch='municipalTreasury';
    insert into public.kp_tree_revisions(branch,revision)
      values('municipalTreasury',treasury_rev+1)
      on conflict(branch) do update set revision=excluded.revision;
  end if;
  return jsonb_build_object('success',true,'commissionCharged',true,'commission',fee,
    'balance',sender_balance-total);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.kp_savings_move(p_direction text, p_amount bigint, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  nick text; root_doc jsonb; profile jsonb; rev bigint;
  balance_now bigint; savings bigint; movement bigint; outcome jsonb;
  earned bigint; day_count bigint; ms bigint;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select nickname into nick from public.kp_profiles where user_id=auth.uid();
  if nick is null then raise exception 'Profile missing'; end if;
  if p_direction is null or p_direction not in ('deposit','withdraw') or p_request_id is null or
    p_amount is null or p_amount<=0 or p_amount>1000000 then
    raise exception 'Invalid savings request';
  end if;
  insert into public.kp_tree_roots(branch) values('users') on conflict do nothing;
  select document,revision into root_doc,rev from public.kp_tree_roots
    where branch='users' for update;
  profile:=root_doc->nick;
  if profile is null then raise exception 'Profile missing'; end if;
  select balance into balance_now from public.kp_wallets
    where user_id=auth.uid() for update;
  if balance_now is null then raise exception 'Wallet missing'; end if;
  if exists(select 1 from public.kp_ledger where operation_id=p_request_id) then
    if not exists(select 1 from public.kp_ledger where operation_id=p_request_id
      and user_id=auth.uid() and kind='savings_move' and account='wallet'
      and details->>'direction'=p_direction
      and amount=case when p_direction='deposit' then -p_amount else p_amount end) then
      raise exception 'Operation identifier conflicts with another request';
    end if;
    return jsonb_build_object('ok',true,'repeated',true,'balance',balance_now,
      'savingsBalance',greatest(0,coalesce((profile->>'savingsBalance')::bigint,0)));
  end if;
  ms:=floor(extract(epoch from clock_timestamp())*1000)::bigint;
  outcome:=public.kp_savings_math_v14(profile,ms);
  profile:=outcome->'profile';
  savings:=(outcome->>'savingsBalance')::bigint;
  earned:=(outcome->>'credited')::bigint;
  day_count:=(outcome->>'days')::bigint;

  if p_direction='deposit' then
    if coalesce(profile->>'accountFrozen','false')='true' or
      coalesce(profile->'roles'->>'migrant','false')='true' then
      raise exception 'Deposits disabled for this account'; end if;
    if balance_now<p_amount then raise exception 'Insufficient wallet funds'; end if;
    if savings+p_amount>1000000000 then raise exception 'Savings balance limit'; end if;
    movement:=-p_amount;savings:=savings+p_amount;
  else
    if savings<p_amount then raise exception 'Insufficient savings funds'; end if;
    if balance_now+p_amount>1000000000 then raise exception 'Wallet balance limit'; end if;
    movement:=p_amount;savings:=savings-p_amount;
  end if;
  balance_now:=balance_now+movement;
  update public.kp_wallets set balance=balance_now,updated_at=now()
    where user_id=auth.uid();
  if earned>0 then
    insert into public.kp_ledger(operation_id,user_id,account,amount,kind,details)
      values(gen_random_uuid(),auth.uid(),'savings',earned,'savings_interest',
        jsonb_build_object('days',day_count,'dailyRate',0.003));
  end if;
  insert into public.kp_ledger(operation_id,user_id,account,amount,kind,details)
    values(p_request_id,auth.uid(),'wallet',movement,'savings_move',
      jsonb_build_object('direction',p_direction,'savings',savings));
  profile:=jsonb_set(profile,'{balance}',to_jsonb(balance_now),true);
  profile:=jsonb_set(profile,'{savingsBalance}',to_jsonb(savings),true);
  root_doc:=jsonb_set(root_doc,array[nick],profile,true);
  update public.kp_tree_roots set document=root_doc,revision=rev+1,updated_at=now()
    where branch='users';
  insert into public.kp_tree_revisions(branch,revision) values('users',rev+1)
    on conflict(branch) do update set revision=excluded.revision;
  return jsonb_build_object('ok',true,'balance',balance_now,
    'savingsBalance',savings,'interestCredited',earned);
end;
$function$
;

-- Background accrual shares the same users-root lock and arithmetic as deposits.
-- Only the scheduler/service role can call this; no Auth impersonation is used.
create or replace function public.kp_savings_accrue_all()
returns jsonb language plpgsql security definer set search_path='' as $$
declare whole jsonb; rev bigint; person record; profile jsonb; outcome jsonb;
  ms bigint := floor(extract(epoch from clock_timestamp())*1000)::bigint;
  earned bigint; total bigint:=0; processed integer:=0; changed boolean:=false;
begin
  select document,revision into whole,rev from public.kp_tree_roots where branch='users' for update;
  if whole is null then return jsonb_build_object('processed',0,'credited',0); end if;
  for person in select user_id,nickname from public.kp_profiles order by user_id loop
    profile:=whole->person.nickname;
    if profile is null then continue; end if;
    outcome:=public.kp_savings_math_v14(profile,ms);
    if not profile ? 'savingsAccrualV14At' or (outcome->>'days')::bigint>0 then
      whole:=jsonb_set(whole,array[person.nickname],outcome->'profile',true);
      earned:=(outcome->>'credited')::bigint;
      if earned>0 then
        insert into public.kp_ledger(operation_id,user_id,account,amount,kind,details)
        values(gen_random_uuid(),person.user_id,'savings',earned,'savings_interest',
          jsonb_build_object('days',(outcome->>'days')::bigint,'dailyRate',0.003,'source','scheduler'));
      end if;
      total:=total+earned;processed:=processed+1;changed:=true;
    end if;
  end loop;
  if changed then
    update public.kp_tree_roots set document=whole,revision=rev+1,updated_at=now() where branch='users';
    insert into public.kp_tree_revisions(branch,revision) values('users',rev+1)
      on conflict(branch) do update set revision=excluded.revision;
  end if;
  return jsonb_build_object('processed',processed,'credited',total);
end;
$$;
revoke all on function public.kp_savings_accrue_all() from public,anon,authenticated;
grant execute on function public.kp_savings_accrue_all() to service_role;

commit;
