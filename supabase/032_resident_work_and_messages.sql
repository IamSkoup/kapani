begin;

create index if not exists kp_v8_bets_user_event_idx on public.kp_v8_bets(user_id,event_id);

-- Lock the users root before the licenses root, matching the civic service.
create or replace function public.kp_update_license_v39(p_target text,p_kind text,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor text:=public.kp_v8_actor(); users jsonb; licenses jsonb; patch jsonb;
begin
  if actor is null then raise exception 'Authentication required'; end if;
  select document into users from public.kp_tree_roots where branch='users' for update;
  if actor<>'Кайон' and (not(public.kp_v8_role(actor,'КСБ') or public.kp_v8_role(actor,'Полицейский'))
      or coalesce(users->actor->>'accountVerified','false')<>'true'
      or users->actor->>'accountFrozen'='true' or users->actor->'roles'->>'migrant'='true') then
    raise exception 'License staff access required';
  end if;
  if p_kind is null or p_kind not in ('bike','scooter') or p_enabled is null then
    raise exception 'Invalid license change';
  end if;
  if users->p_target is null or not exists(select 1 from public.kp_profiles where nickname=p_target) then
    raise exception 'Target account not found';
  end if;

  insert into public.kp_tree_roots(branch) values('licenses') on conflict do nothing;
  select document into licenses from public.kp_tree_roots where branch='licenses' for update;
  patch:=jsonb_build_object(p_kind,p_enabled);
  if p_enabled then
    patch:=patch||jsonb_build_object(p_kind||'IssuedAt',(extract(epoch from clock_timestamp())*1000)::bigint);
  end if;
  perform public.kp_v8_put('licenses',jsonb_set(licenses,array[p_target],coalesce(licenses->p_target,'{}')||patch));
  perform public.kp_v8_put('users',public.kp_tree_set_deep(users,array[p_target,'licenses'],
    coalesce(users->p_target->'licenses','{}')||patch));
  perform public.kp_v8_notify(p_target,
    case when p_enabled then 'Выданы права ' else 'Изъяты права ' end ||
    case when p_kind='bike' then 'на велосипед' else 'на скутер' end,
    'system','license_'||gen_random_uuid()::text);
  return jsonb_build_object('ok',true,'target',p_target,'action','license');
end;
$$;
revoke all on function public.kp_update_license_v39(text,text,boolean) from public,anon,authenticated;
grant execute on function public.kp_update_license_v39(text,text,boolean) to authenticated;

CREATE OR REPLACE FUNCTION public.kp_mayor_update_resident(p_target text, p_action text, p_value jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor text; root_doc jsonb; profile jsonb; rev bigint;
  target_job text; score integer; emps jsonb;
  i integer; new_emps jsonb:='[]'::jsonb; item jsonb; present boolean:=false;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select nickname into actor from public.kp_profiles where user_id=auth.uid();
  if actor is distinct from 'Кайон' then raise exception 'Mayor access required'; end if;
  if not exists(select 1 from public.kp_profiles where nickname=p_target) then
    raise exception 'Target account not found';
  end if;
  insert into public.kp_tree_roots(branch) values('users') on conflict do nothing;
  select document,revision into root_doc,rev from public.kp_tree_roots where branch='users' for update;
  profile:=root_doc->p_target;
  if profile is null then raise exception 'Target account data missing'; end if;
  if p_action='license' then
    return public.kp_update_license_v39(p_target,p_value->>'kind',
      case when jsonb_typeof(p_value->'enabled')='boolean' then (p_value->>'enabled')::boolean end);
  end if;
  if p_action='kve' then
    if jsonb_typeof(p_value)<>'number' or p_value::text !~ '^[0-9]{1,3}$' then
      raise exception 'Invalid exam score'; end if;
    score:=(p_value::text)::integer;
    if score>100 then raise exception 'Exam score outside range'; end if;
    profile:=profile||jsonb_build_object('kveScore',score,
      'kveExamDate',to_char(now() at time zone 'Europe/Moscow','DD.MM.YYYY'),
      'kveScoreSetBy',actor,'kveScoreSetAt',(extract(epoch from clock_timestamp())*1000)::bigint);
  elsif p_action='migrant' then
    if jsonb_typeof(p_value)<>'boolean' or p_target=actor then
      raise exception 'Invalid role change'; end if;
    profile:=jsonb_set(profile,'{roles}',
      coalesce(profile->'roles','{}'::jsonb)||jsonb_build_object('migrant',p_value),true);
  elsif p_action='job' then
    if jsonb_typeof(p_value)<>'string' then raise exception 'Invalid job'; end if;
    target_job:=p_value #>> '{}';
    if target_job not in ('Водитель','Доставщик','Уборщик','Журналист','КСБ',
      'Депутат','Полицейский','Рекламщик','Врач') then raise exception 'Unknown job'; end if;
    emps:=coalesce(profile->'employments','[]'::jsonb);
    if jsonb_typeof(emps)<>'array' then emps:='[]'::jsonb; end if;
    for item in select value from jsonb_array_elements(emps) loop
      if item->>'id'='muni_'||target_job then present:=true; end if;
      if item->>'id'<>'muni_'||target_job then new_emps:=new_emps||jsonb_build_array(item); end if;
    end loop;
    if not present and jsonb_array_length(new_emps)>=5 then
      raise exception 'Employment limit reached'; end if;
    new_emps:=new_emps||jsonb_build_array(jsonb_build_object(
      'id','muni_'||target_job,'type','municipal','role',target_job));
    profile:=profile||jsonb_build_object('job',target_job,'vehicle','',
      'employments',new_emps,'displayJob',coalesce(nullif(profile->>'displayJob',''),target_job));
    if target_job='Уборщик' then
      profile:=profile||jsonb_build_object('janitorSubmissionStatus','ready',
        'janitorSubmissionId','','janitorProof','','janitorComment','');
    end if;
  elsif p_action='fire' then
    if p_target=actor then raise exception 'Mayor cannot fire own account'; end if;
    -- The role used for an employment removal is rechecked on the server.
    target_job:=p_value #>> '{}';
    if target_job is null or length(target_job)>80 then raise exception 'Invalid job to remove'; end if;
    emps:=coalesce(profile->'employments','[]'::jsonb);
    if jsonb_typeof(emps)<>'array' then emps:='[]'::jsonb; end if;
    for item in select value from jsonb_array_elements(emps) loop
      if not (item->>'type'='municipal' and item->>'role'=target_job) then
        new_emps:=new_emps||jsonb_build_array(item);
      else present:=true; end if;
    end loop;
    if not present and profile->>'job'<>target_job then
      raise exception 'Target has no such municipal job'; end if;
    profile:=profile||jsonb_build_object('employments',new_emps,
      'job',coalesce((select x->>'role' from jsonb_array_elements(new_emps) x
        where x->>'type'='municipal' limit 1),'Житель'),
      'displayJob',coalesce((select x->>'role' from jsonb_array_elements(new_emps) x limit 1),'Житель'));
    if target_job in ('Водитель','Доставщик') then profile:=jsonb_set(profile,'{vehicle}','""'::jsonb,true); end if;
  else
    raise exception 'Unsupported mayor operation';
  end if;
  root_doc:=jsonb_set(root_doc,array[p_target],profile,true);
  update public.kp_tree_roots set document=root_doc,revision=rev+1,updated_at=now() where branch='users';
  insert into public.kp_tree_revisions(branch,revision) values('users',rev+1)
    on conflict(branch) do update set revision=excluded.revision;
  return jsonb_build_object('ok',true,'target',p_target,'action',p_action);
end;
$function$;

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
    return jsonb_build_object('success',true,'repeated',true,'commissionCharged',true);
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
  perform public.kp_v8_notify(p_recipient,
    'Перевод от '||sender||': +'||p_amount::text||' ₽', 'money', 'transfer_'||p_request_id::text);
  return jsonb_build_object('success',true,'commissionCharged',true,'commission',fee,
    'balance',sender_balance-total,'recipientBalance',recipient_balance+p_amount);
end;
$function$;

CREATE OR REPLACE FUNCTION public.kp_civic_v8(p_action text, p_kind text, p_id text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a text:=public.kp_v8_actor();u jsonb;d jsonb;o jsonb;l jsonb;b jsonb;branch_name text;target text;fee bigint:=0;accepted boolean;at_ms bigint:=(extract(epoch from now())*1000)::bigint;op uuid;score integer;
begin
 if a is null or length(coalesce(p_id,'')) not between 8 and 100 then raise exception 'Invalid civic request';end if;
 branch_name:=case p_kind when 'janitor' then 'janitorSubmissions' when 'police' then 'policeRequests' when 'business_close' then 'bizDeleteRequests' else 'civicRequests' end;
 if p_kind not in ('janitor','police','business_close','education','bike','scooter') then raise exception 'Unknown request kind';end if;
 select document into u from public.kp_tree_roots where branch='users' for update;
 insert into public.kp_tree_roots(branch)values(branch_name),('licenses') on conflict do nothing;
 select document into d from public.kp_tree_roots where branch=branch_name for update;o:=d->p_id;
 if p_action='submit' then
   if o is not null then if o->>'from'=a or o->>'worker'=a then return o;else raise exception 'Request mismatch';end if;end if;
   if coalesce(u->a->>'accountVerified','false')<>'true' or u->a->>'accountFrozen'='true' then raise exception 'Verified active account required';end if;
   if exists(select 1 from jsonb_each(d)e where coalesce(e.value->>'from',e.value->>'worker')=a and coalesce(e.value->>'kind',p_kind)=p_kind and e.value->>'status'='pending' and p_kind<>'janitor') then raise exception 'Request already pending';end if;
   if p_kind in ('bike','scooter') then
     select document into l from public.kp_tree_roots where branch='licenses' for update;
     if l->a->>p_kind='true' then raise exception 'License already issued';end if;
     fee:=case when p_kind='bike' then 250 else 1500 end;
   elsif p_kind='education' then
     if u->a->'kEducationPurchase'->>'status' in ('paid','submitted','approved') then raise exception 'Education already paid';end if;fee:=2000;
   elsif p_kind='janitor' then
     if not public.kp_v8_role(a,'Уборщик') or length(coalesce(p_data->>'photo',''))<10 then raise exception 'Janitor and proof photo required';end if;
     if exists(select 1 from jsonb_each(d)e where e.value->>'worker'=a and e.value->>'date'=to_char(now() at time zone 'Europe/Moscow','YYYY-MM-DD') and e.value->>'status' in ('pending','approved')) then raise exception 'Today already submitted';end if;
   elsif p_kind='police' then
     if not(public.kp_v8_role(a,'КСБ') or public.kp_v8_role(a,'Полицейский')) or length(trim(coalesce(p_data->>'reason','')))<5 or u->(p_data->>'target') is null then raise exception 'Officer and valid request required';end if;
     if p_data->>'type' not in ('fine','freeze') then raise exception 'Only fine or freeze requests';end if;
     if p_data->>'type'='fine' and (p_data->>'amount' is null or (p_data->>'amount')::bigint not between 1 and 10000) then raise exception 'Fine must be 1 to 10000';end if;
   elsif p_kind='business_close' then
     select document->(p_data->>'bizId') into b from public.kp_tree_roots where branch='businesses';
     if b->>'owner' is distinct from a then raise exception 'Business owner required';end if;
   end if;
   if fee>0 then perform public.kp_v8_money(a,-fee,(md5(p_id||':civic-fee'))::uuid,'civic_fee',jsonb_build_object('kind',p_kind));end if;
   o:=jsonb_build_object('id',p_id,'kind',p_kind,'from',a,'worker',a,'officer',a,'owner',a,'status',case when p_kind='bike' then 'approved' else 'pending' end,'createdAt',at_ms,'feePaid',fee,'date',to_char(now() at time zone 'Europe/Moscow','YYYY-MM-DD'),'comment',left(coalesce(p_data->>'comment',''),1200),'photo',left(coalesce(p_data->>'photo',''),2500000),'target',p_data->>'target','type',p_data->>'type','amount',p_data->'amount','reason',left(coalesce(p_data->>'reason',''),1200),'bizId',p_data->>'bizId');
   select document into u from public.kp_tree_roots where branch='users';
   if p_kind='bike' then perform public.kp_v8_put('licenses',public.kp_tree_set_deep(l,array[a,'bike'],'true'));
   elsif p_kind='scooter' then u:=public.kp_tree_set_deep(u,array[a,'scooterLicenseApplication'],o);
   elsif p_kind='education' then u:=public.kp_tree_set_deep(u,array[a,'kEducationPurchase'],o||'{"status":"submitted"}');
   elsif p_kind='janitor' then u:=jsonb_set(u,array[a],(u->a)||jsonb_build_object('janitorSubmissionId',p_id,'janitorSubmissionStatus','pending','janitorTaskDate',o->>'date'));end if;
   perform public.kp_v8_put('users',u);
 else
   if a<>'Кайон' or p_action not in ('approve','reject') or o is null then raise exception 'Mayor review required';end if;
   if o->>'status'<>'pending' then return o;end if;
   target:=coalesce(o->>'from',o->>'worker',o->>'owner',o->>'officer');accepted:=p_action='approve';op:=(md5(p_id||':civic-review'))::uuid;
   if p_kind='police' and accepted then
     if o->>'type'='fine' then perform public.kp_mayor_fine(o->>'target',(o->>'amount')::bigint,o->>'reason',op);
     else u:=public.kp_tree_set_deep(u,array[o->>'target','accountFrozen'],'true');perform public.kp_v8_put('users',u);end if;
   elsif p_kind='business_close' and accepted then
     select document into b from public.kp_tree_roots where branch='businesses' for update;
     -- Archive instead of deleting orders, staff or financial history.
     b:=public.kp_tree_set_deep(b,array[o->>'bizId','status'],'"archived"');perform public.kp_v8_put('businesses',b);
   elsif p_kind='scooter' and accepted then
     select document into l from public.kp_tree_roots where branch='licenses' for update;perform public.kp_v8_put('licenses',public.kp_tree_set_deep(l,array[target,'scooter'],'true'));
   elsif p_kind in ('education','scooter') and not accepted then
     fee:=coalesce((o->>'feePaid')::bigint,0);if fee>0 then perform public.kp_v8_money(target,fee,op,'civic_refund');end if;
   end if;
   o:=o||jsonb_build_object('status',case when accepted then 'approved' else 'rejected' end,'reviewedAt',at_ms,'adminComment',left(coalesce(p_data->>'comment',''),500));
   select document into u from public.kp_tree_roots where branch='users';
   if p_kind='education' then u:=public.kp_tree_set_deep(u,array[target,'kEducationPurchase'],o);
   elsif p_kind='scooter' then u:=public.kp_tree_set_deep(u,array[target,'scooterLicenseApplication'],o);
   elsif p_kind='janitor' and u->target->>'janitorSubmissionId'=p_id then u:=jsonb_set(u,array[target],(u->target)||jsonb_build_object('janitorSubmissionStatus',o->>'status'));end if;
   perform public.kp_v8_put('users',u);
 end if;
 d:=jsonb_set(d,array[p_id],o,true);perform public.kp_v8_put(branch_name,d);
 perform public.kp_v8_notify(case when p_action='submit' then 'Кайон' else target end,'Заявка: '||case p_kind when 'education' then 'К-образование' when 'scooter' then 'права на скутер' when 'bike' then 'права на велосипед' when 'janitor' then 'отчёт об уборке' when 'police' then 'обращение полиции' else 'закрытие бизнеса' end||' — '||case when p_action='submit' then 'поступила' when p_action='approve' then 'одобрена' else 'отклонена' end,'system','civic_'||p_id||p_action);
 return o;
end; $function$;

CREATE OR REPLACE FUNCTION public.kp_events_v8(p_action text, p_id uuid DEFAULT NULL::uuid, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a text:=public.kp_v8_actor(); e public.kp_v8_events%rowtype; bet public.kp_v8_bets%rowtype; n text; sides jsonb; side integer; stake bigint; pay bigint; total bigint:=0; winning_side integer; arr jsonb; item jsonb; u jsonb;
begin
 if a is null then raise exception 'Authentication required'; end if;
 if p_action='view' then
   select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc),'[]') into arr from (select * from public.kp_v8_events order by created_at desc limit 100)t;
   return jsonb_build_object('events',arr,'bets',coalesce((select jsonb_agg(to_jsonb(b)) from public.kp_v8_bets b where user_id=auth.uid()),'[]'));
 end if;
 select document->a into u from public.kp_tree_roots where branch='users' for update;
 if p_id is null then raise exception 'Request ID required'; end if;
 if p_action='create' then
   if a<>'Кайон' then raise exception 'Mayor access required'; end if;
   if exists(select 1 from public.kp_v8_events where id=p_id) then return jsonb_build_object('ok',true); end if;
   sides:=p_data->'sides';
   if coalesce(jsonb_typeof(sides),'null')<>'array' or jsonb_array_length(sides) not between 2 and 8 or length(trim(coalesce(p_data->>'title',''))) not between 3 and 120 or p_data->>'kind' not in ('sport','battle') then raise exception 'Invalid event'; end if;
   for item in select value from jsonb_array_elements(sides) loop
     if length(trim(coalesce(item->>'name',''))) not between 1 and 80 or item->>'odds' is null or (item->>'odds')::numeric not between 1.01 and 20 then raise exception 'Invalid side or odds'; end if;
   end loop;
   stake:=(p_data->>'budget')::bigint;
   if stake is null or p_data->>'closesAt' is null or stake not between 100 and 100000 or (p_data->>'closesAt')::timestamptz<=now() then raise exception 'Invalid budget or deadline'; end if;
   perform public.kp_v8_money(a,-stake,p_id,'event_reserve',jsonb_build_object('title',p_data->>'title'));
   insert into public.kp_v8_events(id,title,kind,sides,closes_at,budget) values(p_id,trim(p_data->>'title'),p_data->>'kind',sides,(p_data->>'closesAt')::timestamptz,stake);
   return jsonb_build_object('ok',true);
 end if;
 if p_action='bet' then
   select * into bet from public.kp_v8_bets where id=p_id;
   if found then
     if bet.user_id<>auth.uid() or bet.event_id<>(p_data->>'event')::uuid or bet.side<>(p_data->>'side')::integer or bet.stake<>(p_data->>'stake')::bigint then raise exception 'Request mismatch'; end if;
     return to_jsonb(bet);
   end if;
   if coalesce(u->>'accountVerified','false')<>'true' or coalesce(u->>'accountFrozen','false')='true' then raise exception 'Verified active account required'; end if;
   select * into e from public.kp_v8_events where id=(p_data->>'event')::uuid for update;
   side:=(p_data->>'side')::integer;stake:=(p_data->>'stake')::bigint;
   if e.id is null or e.status<>'open' or e.closes_at<=now() or side is null or stake is null or side<0 or side>=jsonb_array_length(e.sides) or stake not between 10 and 2500 then raise exception 'Bet unavailable'; end if;
   if exists(select 1 from public.kp_v8_bets where event_id=e.id and user_id=auth.uid()) then raise exception 'Already bet on this event'; end if;
   pay:=floor(stake*(e.sides->side->>'odds')::numeric);
   if e.liability+pay>e.budget+stake then raise exception 'Event payout reserve exhausted'; end if;
   perform public.kp_v8_money(a,-stake,p_id,'event_bet',jsonb_build_object('event',e.id,'side',side));
   insert into public.kp_v8_bets(id,user_id,event_id,side,stake,payout) values(p_id,auth.uid(),e.id,side,stake,pay);
   update public.kp_v8_events set budget=budget+stake,liability=liability+pay where id=e.id;
 else
   if a<>'Кайон' or p_action not in ('settle','cancel') then raise exception 'Mayor access required'; end if;
   select * into e from public.kp_v8_events where id=p_id for update;
   if e.id is null then raise exception 'Event missing'; end if;
   if e.status<>'open' then return jsonb_build_object('ok',true,'repeated',true); end if;
   winning_side:=(p_data->>'winner')::integer;
   if p_action='settle' and (winning_side is null or winning_side<0 or winning_side>=jsonb_array_length(e.sides) or now()<e.closes_at) then raise exception 'Wait for closing and select winner'; end if;
   for bet in select * from public.kp_v8_bets where event_id=e.id order by user_id loop
     pay:=case when p_action='cancel' then bet.stake when bet.side=winning_side then bet.payout else 0 end;
     if pay>0 then
       select nickname into n from public.kp_profiles where user_id=bet.user_id;
       perform public.kp_v8_money(n,pay,(md5(bet.id::text||':result'))::uuid,'event_result',jsonb_build_object('event',e.id));
       total:=total+pay;
     end if;
     update public.kp_v8_bets set status=case when p_action='cancel' then 'refunded' when pay>0 then 'won' else 'lost' end where id=bet.id;
   end loop;
   perform public.kp_v8_money(a,e.budget-total,(md5(e.id::text||':remainder'))::uuid,'event_reserve_return');
   update public.kp_v8_events set status=case when p_action='cancel' then 'cancelled' else 'settled' end,winner=winning_side,budget=0 where id=e.id;
 end if;
 return jsonb_build_object('ok',true);
end; $function$;

CREATE OR REPLACE FUNCTION public.kp_casino_v8(p_action text, p_id uuid DEFAULT NULL::uuid, p_amount bigint DEFAULT 0, p_game text DEFAULT NULL::text, p_choice text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a text:=public.kp_v8_actor(); u jsonb; c public.kp_v8_casino_accounts%rowtype; old public.kp_v8_casino_ops%rowtype; args jsonb; result jsonb; payout bigint:=0; outcome jsonb; x integer; y integer; z integer; main bigint; today date:=(now() at time zone 'Europe/Moscow')::date;
begin
 if a is null then raise exception 'Authentication required'; end if;
 if p_action='view' then
   select * into c from public.kp_v8_casino_accounts where user_id=auth.uid();
   select balance into main from public.kp_wallets where user_id=auth.uid();
   return jsonb_build_object('balance',coalesce(c.balance,0),'main',main,
     'dailyWagerRemaining',greatest(0,20000-case when c.day=today then c.wagers else 0 end));
 end if;
 select document->a into u from public.kp_tree_roots where branch='users' for update;
 insert into public.kp_v8_casino_accounts(user_id,day) values(auth.uid(),today) on conflict do nothing;
 select * into c from public.kp_v8_casino_accounts where user_id=auth.uid() for update;
 select balance into main from public.kp_wallets where user_id=auth.uid();
 if c.day is distinct from today then c.day:=today;c.deposits:=0;c.wagers:=0; end if;
 if p_action not in ('deposit','withdraw','play') or p_id is null then raise exception 'Invalid operation'; end if;
 args:=jsonb_build_object('action',p_action,'amount',p_amount,'game',p_game,'choice',p_choice);
 select * into old from public.kp_v8_casino_ops where id=p_id;
 if found then
   if old.user_id<>auth.uid() or old.args<>args then raise exception 'Request identifier mismatch'; end if;
   return old.result;
 end if;
 if coalesce(u->>'accountFrozen','false')='true' or coalesce(u->>'accountVerified','false')<>'true' or coalesce(u->'roles'->>'migrant','false')='true' then raise exception 'Verified active account required'; end if;
 if p_amount is null or p_amount<1 or p_amount>10000 then raise exception 'Amount must be between 1 and 10000'; end if;
 if p_action='deposit' then
   if c.deposits+p_amount>10000 then raise exception 'Daily deposit limit: 10000'; end if;
   main:=public.kp_v8_money(a,-p_amount,p_id,'casino_deposit'); c.balance:=c.balance+p_amount; c.deposits:=c.deposits+p_amount;
 elsif p_action='withdraw' then
   if c.balance<p_amount then raise exception 'Insufficient casino balance'; end if;
   main:=public.kp_v8_money(a,p_amount,p_id,'casino_withdraw'); c.balance:=c.balance-p_amount;
 else
   if p_amount>1000 or c.wagers+p_amount>20000 then raise exception 'Stake limit: 1000; daily turnover: 20000'; end if;
   if c.balance<p_amount then raise exception 'Insufficient casino balance'; end if;
   if c.last_round>clock_timestamp()-interval '2 seconds' then raise exception 'Wait for the current round'; end if;
   if p_game='roulette' then
     if p_choice is null or p_choice not in ('red','black','zero') then raise exception 'Select a roulette field'; end if;
     x:=public.kp_v8_random(37); outcome:=to_jsonb(x);
     if (p_choice='zero' and x=0) then payout:=p_amount*36;
     elsif x>0 and ((p_choice='red' and x=any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36])) or (p_choice='black' and not(x=any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36])))) then payout:=p_amount*2; end if;
   elsif p_game='dice' then
     if coalesce(p_choice,'') !~ '^[1-6]$' then raise exception 'Choose 1 to 6'; end if;
     x:=public.kp_v8_random(6)+1;outcome:=to_jsonb(x);if x=p_choice::integer then payout:=floor(p_amount*5.7);end if;
   elsif p_game='slots' then
     x:=public.kp_v8_random(6);y:=public.kp_v8_random(6);z:=public.kp_v8_random(6);outcome:=jsonb_build_array(x,y,z);
     if x=y and y=z then payout:=p_amount*12;elsif x=y or y=z or x=z then payout:=floor(p_amount*1.5);end if;
   elsif p_game='wheel' then
     x:=public.kp_v8_random(20);y:=case when x<11 then 0 when x<16 then 1 when x<18 then 2 else 5 end;outcome:=to_jsonb(y);payout:=p_amount*y;
   else raise exception 'Unknown game'; end if;
   c.balance:=c.balance-p_amount+payout;c.wagers:=c.wagers+p_amount;c.last_round:=clock_timestamp();
 end if;
 update public.kp_v8_casino_accounts set balance=c.balance,day=c.day,deposits=c.deposits,wagers=c.wagers,last_round=c.last_round where user_id=auth.uid();
 result:=jsonb_build_object('id',p_id,'balance',c.balance,'main',main,'outcome',outcome,'payout',payout,'stake',p_amount,'game',p_game);
 insert into public.kp_v8_casino_ops(id,user_id,args,result) values(p_id,auth.uid(),args,result);
 return result;
end; $function$;

CREATE OR REPLACE FUNCTION public.kp_message_v8(p_action text, p_kind text, p_peer text DEFAULT NULL::text, p_id text DEFAULT NULL::text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a text:=public.kp_v8_actor(); b text; conv text; path text[]; root jsonb; msg jsonb; users jsonb; attachment jsonb; reply jsonb; emoji text; target jsonb; idx jsonb; gift public.kp_v10_subscription_ops%rowtype; at_ms bigint:=(extract(epoch from now())*1000)::bigint;
begin
 if a is null or p_kind not in ('chat','dm') or coalesce(p_id,'')!~ '^[A-Za-z0-9_-]{8,100}$' then raise exception 'Invalid message request'; end if;
 if p_kind='dm' then
   if p_peer is null or not exists(select 1 from public.kp_profiles where nickname=p_peer) then raise exception 'Recipient missing'; end if;
   conv:=case when a collate "C" < p_peer collate "C" then a||'__dm__'||p_peer else p_peer||'__dm__'||a end;
   b:='dms';path:=array[conv,'messages',p_id];
 else b:='chat';path:=array[p_id];end if;
 select document into users from public.kp_tree_roots where branch='users';
 insert into public.kp_tree_roots(branch) values(b) on conflict do nothing;
 select document into root from public.kp_tree_roots where branch=b for update;
 msg:=root #> path;
 if p_action='send' then
   if msg is not null then
     if msg->>'nick'<>a then raise exception 'Message identifier collision'; end if;
     return msg;
   end if;
   if length(coalesce(p_data->>'text',''))>4000 or jsonb_typeof(coalesce(p_data->'attachments','[]'))<>'array' or jsonb_array_length(coalesce(p_data->'attachments','[]'))>6 then raise exception 'Message limit exceeded'; end if;
   for attachment in select value from jsonb_array_elements(coalesce(p_data->'attachments','[]')) loop
     if attachment->>'type' is null or attachment->>'type' not in ('image','video','voice','video_circle','sticker') or coalesce(attachment->>'url','')!~ '^https://' or length(attachment->>'url')>2000 then raise exception 'Invalid attachment'; end if;
   end loop;
   msg:=jsonb_build_object('nick',a,'avatar',users->a->>'avatar','text',left(coalesce(p_data->>'text',''),4000),'attachments',coalesce(p_data->'attachments','[]'),'createdAt',at_ms,'time',to_char(now() at time zone 'Europe/Moscow','HH24:MI'));
   if p_data ? 'giftOperation' then
     select * into gift from public.kp_v10_subscription_ops
       where id=(p_data->>'giftOperation')::uuid and actor=a and action='gift' and recipient=p_peer;
     if not found or p_kind<>'dm' or p_id<>'gift_'||gift.id::text then raise exception 'Gift unavailable'; end if;
     msg:=(msg-'avatar')||jsonb_build_object('text','Подарок — Kapani '||initcap(gift.plan),
       'subscriptionGift',jsonb_build_object('plan',gift.plan,'expiresAt',gift.result->>'expiresAt'));
   elsif starts_with(p_id,'gift_') then
     raise exception 'Reserved message identifier';
   end if;
   if p_data ? 'replyId' then
     reply:=root #> (case when p_kind='chat' then array[p_data->>'replyId'] else array[conv,'messages',p_data->>'replyId'] end);
     if reply is not null then msg:=msg||jsonb_build_object('reply',jsonb_build_object('id',p_data->>'replyId','nick',reply->>'nick','text',left(coalesce(reply->>'text','Вложение'),180)));end if;
   end if;
   if p_data ? 'forward' then
     target:=public.kp_tree_access('read',p_data->'forward'->>'path');reply:=target->'value';
     if (p_data->'forward'->>'path') !~ '^(chat/[^/]+|dms/[^/]+/messages/[^/]+)$' or reply is null or reply->>'nick' is null then raise exception 'Forwarded message unavailable'; end if;
     msg:=msg||jsonb_build_object('text',reply->>'text','attachments',coalesce(reply->'attachments',case when reply->>'mediaData' is not null then jsonb_build_array(jsonb_build_object('url',reply->>'mediaData','type',reply->>'msgType')) else '[]'::jsonb end),'forwardedFrom',reply->>'nick');
   end if;
   if coalesce(msg->>'text','')='' and jsonb_array_length(msg->'attachments')=0 then raise exception 'Empty message'; end if;
 elsif p_action='reaction' then
   if msg is null then raise exception 'Message missing'; end if;
   emoji:=p_data->>'emoji';if emoji not in ('👍','😂','🔥','😮','😢') then raise exception 'Unsupported reaction'; end if;
   target:=coalesce(msg->'reactions','{}');
   if target->>a=emoji then target:=target-a;else target:=jsonb_set(target,array[a],to_jsonb(emoji),true);end if;
   msg:=msg||jsonb_build_object('reactions',target);
 elsif p_action='edit' then
   if msg is null or msg->>'nick'<>a or msg ? 'subscriptionGift' then raise exception 'Message cannot be edited'; end if;
   if length(trim(coalesce(p_data->>'text',''))) not between 1 and 4000 then raise exception 'Invalid message text';end if;
   msg:=msg||jsonb_build_object('text',trim(p_data->>'text'),'caption',trim(p_data->>'text'),'edited',true);
 elsif p_action='delete' then
   if msg is null then return jsonb_build_object('ok',true);end if;
   if msg->>'nick'<>a then raise exception 'Only author can delete'; end if;
   root:=root #- path;perform public.kp_v8_put(b,root);return jsonb_build_object('ok',true);
 else raise exception 'Unknown message action';end if;
 root:=public.kp_tree_set_deep(root,path,msg);perform public.kp_v8_put(b,root);
 if p_kind='dm' and p_action='send' then
   insert into public.kp_tree_roots(branch) values('dmIndex') on conflict do nothing;
   select document into idx from public.kp_tree_roots where branch='dmIndex' for update;
   target:=jsonb_build_object('lastTs',at_ms,'latest',msg);
   idx:=public.kp_tree_set_deep(idx,array[a,p_peer],target||'{"unread":false}');
   idx:=public.kp_tree_set_deep(idx,array[p_peer,a],target||'{"unread":true}');
   perform public.kp_v8_put('dmIndex',idx);
 end if;
 return msg;
end; $function$;

CREATE OR REPLACE FUNCTION public.kp_subscription_v10(p_action text, p_id uuid, p_plan text DEFAULT NULL::text, p_recipient text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a text:=public.kp_v8_actor();users jsonb;payer jsonb;target jsonb;
 target_nick text;old public.kp_v10_subscription_ops%rowtype;
 price bigint:=0;wallet_after bigint;expiry timestamptz;existing_expiry timestamptz;
 old_rank integer;new_rank integer;plan_start timestamptz:=now();
 result jsonb;treasury jsonb;now_ms bigint:=(extract(epoch from now())*1000)::bigint;
begin
 if a is null or p_id is null or p_action not in ('buy','gift','cancel') then raise exception 'Invalid subscription request';end if;
 select document into users from public.kp_tree_roots where branch='users' for update;
 payer:=users->a;
 if payer is null or payer->>'accountFrozen'='true' or coalesce(payer->>'accountVerified','false')<>'true' then
   raise exception 'Verified active account required';
 end if;
 select * into old from public.kp_v10_subscription_ops where id=p_id;
 if found then
   if old.actor<>a or old.action<>p_action or old.plan is distinct from p_plan
     or old.recipient is distinct from p_recipient then raise exception 'Subscription retry mismatch';end if;
   return old.result;
 end if;
 if p_action='cancel' then
   users:=jsonb_set(users,array[a,'subscriptionAutoRenew'],'false'::jsonb,true);
   perform public.kp_v8_put('users',users);
   result:=jsonb_build_object('success',true,'subscription',payer->>'subscription',
     'expiresAt',payer->>'subscriptionExpiry','cancelledRenewal',true);
 else
   price:=case p_plan when 'plus' then 299 when 'ultra' then 899 when 'prime' then 1499 else null end;
   if price is null then raise exception 'Unknown subscription plan';end if;
   target_nick:=case when p_action='gift' then nullif(trim(coalesce(p_recipient,'')),'') else a end;
   if target_nick is null or (p_action='gift' and target_nick=a) then raise exception 'Choose another recipient';end if;
   target:=users->target_nick;
   if target is null or target->>'accountFrozen'='true' then raise exception 'Recipient unavailable';end if;
   existing_expiry:=case when coalesce(target->>'subscriptionExpiry','') ~ '^20[0-9][0-9]-'
     then (target->>'subscriptionExpiry')::timestamptz else null end;
   old_rank:=case when existing_expiry>now() then
     case target->>'subscription' when 'plus' then 1 when 'ultra' then 2 when 'prime' then 3 else 0 end
     else 0 end;
   new_rank:=case p_plan when 'plus' then 1 when 'ultra' then 2 else 3 end;
   if p_action='gift' and old_rank>new_rank then raise exception 'Recipient has a higher subscription';end if;
   -- A same-plan purchase extends; a different plan starts a fresh seven-day term.
   expiry:=case when old_rank=new_rank and target->>'subscription'=p_plan and existing_expiry>now()
     then existing_expiry+interval '7 days' else now()+interval '7 days' end;
   wallet_after:=public.kp_v8_money(a,-price,p_id,'subscription_'||p_action,
     jsonb_build_object('plan',p_plan,'recipient',target_nick));
   -- kp_v8_money has just updated users/<payer>/balance. Read that version.
   select document into users from public.kp_tree_roots where branch='users';
   target:=users->target_nick;
   if old_rank=new_rank and target->>'subscription'=p_plan and existing_expiry>now() then
     plan_start:=coalesce(nullif(target->>'subscriptionStart','')::timestamptz,now());
   end if;
   target:=target||jsonb_build_object('subscription',p_plan,'subscriptionExpiry',to_char(expiry at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
     'subscriptionStart',to_char(plan_start at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
     'subscriptionAutoRenew',false);
   perform public.kp_v8_put('users',jsonb_set(users,array[target_nick],target));
   insert into public.kp_tree_roots(branch) values('municipalTreasury') on conflict do nothing;
   select document into treasury from public.kp_tree_roots where branch='municipalTreasury' for update;
   treasury:=coalesce(treasury,'{}'::jsonb)||jsonb_build_object('balance',coalesce((treasury->>'balance')::bigint,0)+price);
   perform public.kp_v8_put('municipalTreasury',treasury);
   result:=jsonb_build_object('success',true,'subscription',p_plan,'recipient',target_nick,
     'price',price,'balance',wallet_after,'expiresAt',expiry,'transactionId',p_id);
   perform public.kp_v8_notify(target_nick,
     case when p_action='gift' then 'Подарена подписка '||p_plan||' от '||a else 'Подписка '||p_plan||' оплачена' end,
     'system','subscription_'||p_id::text);
 end if;
 insert into public.kp_v10_subscription_ops(id,actor,action,plan,recipient,result)
 values(p_id,a,p_action,p_plan,p_recipient,result);
 if p_action='gift' then
   perform public.kp_message_v8('send','dm',target_nick,'gift_'||p_id::text,
     jsonb_build_object('giftOperation',p_id));
 end if;
 return result;
end; $function$;

-- Photo reports are counted by work date in Moscow, regardless of review date.
create or replace function public.kp_janitor_weeks_v39()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor text:=public.kp_v8_actor(); reports jsonb;
begin
  if actor is distinct from 'Кайон' then raise exception 'Mayor access required'; end if;
  select document into reports from public.kp_tree_roots where branch='janitorSubmissions';
  return coalesce((
    select jsonb_agg(to_jsonb(w)||jsonb_build_object('paid',exists(
      select 1 from public.kp_ledger l where l.operation_id=md5('janitor:'||w.user_id||':'||w.week)::uuid
    )) order by w.week desc,w.worker)
    from (
      select p.user_id,p.nickname as worker,date_trunc('week',(e.value->>'date')::date::timestamp)::date as week,
        count(distinct e.value->>'date') as approved
      from jsonb_each(coalesce(reports,'{}')) e join public.kp_profiles p
        on p.nickname=coalesce(e.value->>'worker',e.value->>'from')
      where e.value->>'status'='approved' and e.value->>'date' ~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$'
        and coalesce(e.value->>'reward','0') in ('0','')
        and not exists(select 1 from public.kp_ledger l
          where l.operation_id=md5(e.key||':civic-review')::uuid and l.kind='janitor_reward')
      group by 1,2,3 having count(distinct e.value->>'date')>=5
    ) w
  ),'[]');
end;
$$;
revoke all on function public.kp_janitor_weeks_v39() from public,anon,authenticated;
grant execute on function public.kp_janitor_weeks_v39() to authenticated;

create or replace function public.kp_pay_janitor_week_v39(p_target text,p_week date,p_amount bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare candidate jsonb; operation uuid;
begin
  if public.kp_v8_actor() is distinct from 'Кайон' then raise exception 'Mayor access required'; end if;
  if p_amount is null or p_amount not between 1 and 1000000 then raise exception 'Invalid amount'; end if;
  perform 1 from public.kp_tree_roots where branch='users' for update;
  select w into candidate from jsonb_array_elements(public.kp_janitor_weeks_v39()) w
    where w->>'worker'=p_target and w->>'week'=p_week::text;
  if candidate is null then raise exception 'Janitor weekly target not met'; end if;
  operation:=md5('janitor:'||(candidate->>'user_id')||':'||p_week::text)::uuid;
  if exists(select 1 from public.kp_ledger where operation_id=operation) then
    return jsonb_build_object('ok',true,'repeated',true);
  end if;
  perform public.kp_v8_money(p_target,p_amount,operation,'janitor_weekly_salary',
    jsonb_build_object('week',p_week,'approved',candidate->'approved'));
  perform public.kp_v8_notify(p_target,'Зарплата за уборку: +'||p_amount::text||' ₽',
    'money','janitor_'||p_week::text);
  return jsonb_build_object('ok',true);
end;
$$;
revoke all on function public.kp_pay_janitor_week_v39(text,date,bigint) from public,anon,authenticated;
grant execute on function public.kp_pay_janitor_week_v39(text,date,bigint) to authenticated;

-- The inbox only needs compact previews. History is fetched when a chat is opened.
create or replace function public.kp_chat_read_v39(p_path text,p_limit integer default 80)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor text:=public.kp_v8_actor(); parts text[]:=string_to_array(p_path,'/'); messages jsonb;
begin
  if actor is null then raise exception 'Authentication required'; end if;
  if p_path='chat' then
    select document into messages from public.kp_tree_roots where branch='chat';
  elsif parts=array['dmIndex',actor] then
    return coalesce((
      select jsonb_object_agg(e.key, e.value||jsonb_build_object('latest',
        case when e.value->'latest' is not null then (e.value->'latest')-array['avatar','mediaData','reactions'] else null end))
      from public.kp_tree_roots r cross join lateral jsonb_each(coalesce(r.document->actor,'{}')) e
      where r.branch='dmIndex'
    ),'{}');
  elsif cardinality(parts)=3 and parts[1]='dms' and parts[3]='messages' and
      (split_part(parts[2],'__dm__',1)=actor or split_part(parts[2],'__dm__',2)=actor) then
    select document #> array[parts[2],'messages'] into messages from public.kp_tree_roots where branch='dms';
  else
    raise exception 'Chat unavailable';
  end if;
  return coalesce((
    select jsonb_object_agg(m.key,case when length(m.value->>'avatar')>2000 then m.value-'avatar' else m.value end)
    from (
      select key,value from jsonb_each(coalesce(messages,'{}')) where jsonb_typeof(value)='object'
      order by case when value->>'createdAt' ~ '^[0-9]{1,16}$' then (value->>'createdAt')::bigint else 0 end desc,key desc
      limit greatest(1,least(coalesce(p_limit,80),80))
    ) m
  ),'{}');
end;
$$;
revoke all on function public.kp_chat_read_v39(text,integer) from public,anon,authenticated;
grant execute on function public.kp_chat_read_v39(text,integer) to authenticated;

create or replace function public.kp_chat_mark_dm_read_v39(p_peer text)
returns void language plpgsql security definer set search_path='' as $$
declare actor text:=public.kp_v8_actor(); conversation text; inbox jsonb; messages jsonb;
  at_ms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
  if actor is null or p_peer is null or p_peer=actor then raise exception 'Chat unavailable'; end if;
  conversation:=case when actor collate "C"<p_peer collate "C" then actor||'__dm__'||p_peer else p_peer||'__dm__'||actor end;
  select document into messages from public.kp_tree_roots where branch='dms' for update;
  if messages->conversation is null then return; end if;
  select document into inbox from public.kp_tree_roots where branch='dmIndex' for update;
  if inbox#>>array[actor,p_peer,'unread']='true' then
    perform public.kp_v8_put('dmIndex',jsonb_set(inbox,array[actor,p_peer,'unread'],'false'));
  end if;
  if coalesce(messages#>>array[conversation,'lastRead',actor],'0') ~ '^[0-9]{1,16}$' and
      coalesce(messages#>>array[conversation,'lastRead',actor],'0')::bigint>=at_ms then return; end if;
  perform public.kp_v8_put('dms',public.kp_tree_set_deep(messages,
    array[conversation,'lastRead',actor],to_jsonb(at_ms)));
end;
$$;
revoke all on function public.kp_chat_mark_dm_read_v39(text) from public,anon,authenticated;
grant execute on function public.kp_chat_mark_dm_read_v39(text) to authenticated;

create or replace function public.kp_live_users_v39()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor text:=public.kp_v8_actor(); result jsonb;
begin
  if actor is null then raise exception 'Authentication required'; end if;
  select coalesce(jsonb_object_agg(u.key,coalesce((
    select jsonb_object_agg(f.key,f.value)
    from jsonb_each(case when actor='Кайон' then u.value else public.kp_v8_public_profile(u.value) end) f
    where f.key in ('balance','lastSeen','job','displayJob','displayName','subscription',
      'subscriptionExpiry','accountFrozen','accountVerified','taskBalance','savingsBalance',
      'kveScore','fine','employments','totalEarned','nicknameEmoji','avatarFrame')
  ),'{}')),'{}') into result
  from public.kp_tree_roots r cross join lateral jsonb_each(r.document) u
  where r.branch='users' and u.key<>actor;
  return result;
end;
$$;
revoke all on function public.kp_live_users_v39() from public,anon,authenticated;
grant execute on function public.kp_live_users_v39() to authenticated;

commit;
