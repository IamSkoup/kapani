-- Fix weekly tax collection so savings transfers do not shield assets.
-- Apply after 033_distinguish_freeze_from_deletion.sql.
begin;
create or replace function public.kp_process_economy_charges()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  nick text; users_root jsonb; treasury jsonb; user_doc jsonb;
  u_rev bigint; t_rev bigint; wallet_balance bigint; savings bigint;
  current_ms bigint; marker bigint; completed bigint; weeks integer;
  i integer; tax_base bigint; tax_rate numeric; assessment bigint; debit bigint;
  total_debit bigint:=0; total_wallet_debit bigint:=0; total_savings_debit bigint:=0;
  wallet_debit bigint; savings_debit bigint; movement uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select nickname into nick from public.kp_profiles where user_id=auth.uid();
  if nick is null then raise exception 'Profile registration required'; end if;
  insert into public.kp_tree_roots(branch) values('users') on conflict do nothing;
  insert into public.kp_tree_roots(branch) values('municipalTreasury') on conflict do nothing;
  select document,revision into users_root,u_rev from public.kp_tree_roots where branch='users' for update;
  user_doc:=users_root->nick;
  if user_doc is null then raise exception 'Profile document missing'; end if;
  select balance into wallet_balance from public.kp_wallets where user_id=auth.uid() for update;
  if wallet_balance is null then raise exception 'Protected wallet missing'; end if;
  current_ms:=(extract(epoch from clock_timestamp())*1000)::bigint;
  marker:=nullif(user_doc->>'economyLastProcessedAt','')::bigint;
  if marker is null or marker>current_ms then marker:=current_ms; end if;
  weeks:=least(52,greatest(0,((current_ms-marker)/604800000)::integer));
  if weeks=0 then
    if not (user_doc ? 'economyLastProcessedAt') then
      users_root:=jsonb_set(users_root,array[nick,'economyLastProcessedAt'],to_jsonb(marker),true);
      update public.kp_tree_roots set document=users_root,revision=u_rev+1,updated_at=now() where branch='users';
      insert into public.kp_tree_revisions(branch,revision) values('users',u_rev+1)
        on conflict(branch) do update set revision=excluded.revision;
    end if;
    return jsonb_build_object('ok',true,'weeks',0,'charged',0,'balance',wallet_balance);
  end if;
  savings:=greatest(0,coalesce((user_doc->>'savingsBalance')::bigint,0));
  for i in 1..weeks loop
    tax_base:=greatest(0,wallet_balance)+savings;
    tax_rate:=case when tax_base<1000 then 0.07 when tax_base<=10000 then 0.10
      when tax_base<=100000 then 0.17 else 0.25 end;
    assessment:=15+round(tax_base*tax_rate)::bigint;
    -- Pay from wallet first, then savings. Moving funds between accounts
    -- cannot reduce the bill; never spend more than the combined funds.
    wallet_debit:=least(greatest(0,wallet_balance),assessment);
    savings_debit:=least(savings,assessment-wallet_debit);
    wallet_balance:=wallet_balance-wallet_debit;
    savings:=savings-savings_debit;
    total_wallet_debit:=total_wallet_debit+wallet_debit;
    total_savings_debit:=total_savings_debit+savings_debit;
    total_debit:=total_debit+wallet_debit+savings_debit;
  end loop;
  completed:=marker+(weeks::bigint*604800000);
  update public.kp_wallets set balance=wallet_balance,updated_at=now() where user_id=auth.uid();
  users_root:=jsonb_set(users_root,array[nick,'balance'],to_jsonb(wallet_balance),true);
  users_root:=jsonb_set(users_root,array[nick,'savingsBalance'],to_jsonb(savings),true);
  users_root:=jsonb_set(users_root,array[nick,'economyLastProcessedAt'],to_jsonb(completed),true);
  update public.kp_tree_roots set document=users_root,revision=u_rev+1,updated_at=now() where branch='users';
  insert into public.kp_tree_revisions(branch,revision) values('users',u_rev+1)
    on conflict(branch) do update set revision=excluded.revision;
  if total_debit>0 then
    movement:=gen_random_uuid();
    if total_wallet_debit>0 then
      insert into public.kp_ledger(operation_id,user_id,account,amount,kind,details)
        values(movement,auth.uid(),'wallet',-total_wallet_debit,'weekly_economy_charges',
          jsonb_build_object('weeks',weeks,'fees_and_taxes',total_wallet_debit));
    end if;
    if total_savings_debit>0 then
      insert into public.kp_ledger(operation_id,user_id,account,amount,kind,details)
        values(movement,auth.uid(),'savings',-total_savings_debit,'weekly_economy_charges',
          jsonb_build_object('weeks',weeks,'fees_and_taxes',total_savings_debit));
    end if;
    select document,revision into treasury,t_rev from public.kp_tree_roots
      where branch='municipalTreasury' for update;
    treasury:=jsonb_set(treasury,'{balance}',to_jsonb(coalesce((treasury->>'balance')::bigint,0)+total_debit),true);
    update public.kp_tree_roots set document=treasury,revision=t_rev+1,updated_at=now()
      where branch='municipalTreasury';
    insert into public.kp_tree_revisions(branch,revision) values('municipalTreasury',t_rev+1)
      on conflict(branch) do update set revision=excluded.revision;
  end if;
  return jsonb_build_object('ok',true,'weeks',weeks,'charged',total_debit,
    'walletCharged',total_wallet_debit,'savingsCharged',total_savings_debit,
    'balance',wallet_balance,'savingsBalance',savings);
end;
$$;
revoke all on function public.kp_process_economy_charges() from public,anon;
grant execute on function public.kp_process_economy_charges() to authenticated;
commit;
