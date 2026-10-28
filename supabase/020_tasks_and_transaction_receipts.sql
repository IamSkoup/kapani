-- Apply after 019. Server-verified daily rewards and readable ledger receipts.
begin;
create or replace function public.kp_claim_task(p_kind text,p_task_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  nick text; whole jsonb; profile jsonb; rev bigint; reward integer:=0;
  day_key text; day_start bigint; day_end bigint; claimed_key text; claimed jsonb;
  task_names text[]:=array['chat','wall','transfer','shop','taxi_req','market_browse','dm'];
  prime_names text[]:=array['prime_listing','prime_transfer_big','prime_taxi2',
      'prime_chat5','prime_dm3','prime_shop_big'];
  task_rewards integer[]:=array[10,10,15,20,20,5,10];
  prime_rewards integer[]:=array[60,70,90,50,65,80];
  seed integer; n integer; i integer; j integer; swap text;
  allowed_today boolean:=false; proof boolean:=false; recent_count integer:=0;
  root_doc jsonb; item jsonb; message jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select nickname into nick from public.kp_profiles where user_id=auth.uid();
  if nick is null then raise exception 'Profile not found'; end if;
  if length(coalesce(p_task_id,''))>60 then raise exception 'Invalid task identifier'; end if;
  day_key:=to_char(now() at time zone 'Europe/Moscow','YYYY-MM-DD');
  day_start:=(extract(epoch from (day_key::date::timestamp at time zone 'Europe/Moscow'))*1000)::bigint;
  day_end:=(extract(epoch from ((day_key::date+1)::timestamp at time zone 'Europe/Moscow'))*1000)::bigint;
  insert into public.kp_tree_roots(branch) values('users') on conflict do nothing;
  select document,revision into whole,rev from public.kp_tree_roots where branch='users' for update;
  profile:=whole->nick;
  if profile is null then raise exception 'Profile data missing'; end if;
  if coalesce((profile->>'roles')::jsonb->>'migrant','false')='true' then
    raise exception 'Tasks are not available for this account'; end if;
  if p_kind='daily' then
    claimed_key:='dailyClaimed_'||day_key;
    claimed:=coalesce(profile->claimed_key,'[]'::jsonb);
    if jsonb_typeof(claimed)<>'array' then claimed:='[]'::jsonb; end if;
    if claimed ? p_task_id then return jsonb_build_object('claimed',false,'reason','already claimed'); end if;
    n:=array_length(task_names,1);
    seed:=(to_char(day_key::date,'YYYYMMDD')::integer % 997);
    for i in reverse n..2 loop
      j:=((seed*i+(i-1)*37)%n)+1;
      swap:=task_names[i];task_names[i]:=task_names[j];task_names[j]:=swap;
    end loop;
    allowed_today:=p_task_id=any(task_names[1:3]);
    if not allowed_today then
      if profile->>'subscription'='prime' and
        coalesce((profile->>'subscriptionExpiry')::timestamptz,now()-interval '1 day')>now() then
        n:=array_length(prime_names,1);
        seed:=((to_char(day_key::date,'YYYYMMDD')::integer*31)%991);
        for i in reverse n..2 loop
          j:=((seed*i+(i-1)*53)%n)+1;
          swap:=prime_names[i];prime_names[i]:=prime_names[j];prime_names[j]:=swap;
        end loop;
        allowed_today:=p_task_id=any(prime_names[1:2]);
      end if;
    end if;
    if not allowed_today then raise exception 'Task is not active today'; end if;
    if p_task_id=any(array['chat','wall','dm','market_browse']) then
      reward:=case p_task_id when 'chat' then 10 when 'wall' then 10
               when 'dm' then 10 when 'market_browse' then 5 end;
    elsif p_task_id in ('prime_chat5','prime_dm3') then
      reward:=case p_task_id when 'prime_chat5' then 50 else 65 end;
    elsif p_task_id=any(array['transfer','shop','taxi_req','prime_listing','prime_transfer_big','prime_taxi2','prime_shop_big']) then
      reward:=case p_task_id when 'transfer' then 15 when 'shop' then 20
        when 'taxi_req' then 20 when 'prime_listing' then 60
        when 'prime_transfer_big' then 70 when 'prime_taxi2' then 90
        when 'prime_shop_big' then 80 end;
    else
      raise exception 'Unknown task';
    end if;
    if p_task_id='market_browse' then
      proof:=true;
    elsif p_task_id in ('chat','prime_chat5') then
      select count(*) into recent_count from public.kp_tree_roots r,
          jsonb_each(coalesce(r.document,'{}'::jsonb)) m
        where r.branch='chat' and m.value->>'nick'=nick
          and (case when m.value->>'createdAt' ~ '^[0-9]{13}$'
                    then (m.value->>'createdAt')::bigint else 0 end) >= day_start
          and (case when m.value->>'createdAt' ~ '^[0-9]{13}$'
                    then (m.value->>'createdAt')::bigint else 0 end) < day_end;
      proof:=recent_count >= case when p_task_id='prime_chat5' then 5 else 1 end;
    elsif p_task_id='wall' then
      select count(*) into recent_count from public.kp_tree_roots r,
          jsonb_each(coalesce(r.document->nick,'{}'::jsonb)) m
        where r.branch='walls'
          and (case when m.value->>'createdAt' ~ '^[0-9]{13}$'
                    then (m.value->>'createdAt')::bigint else 0 end) >= day_start
          and (case when m.value->>'createdAt' ~ '^[0-9]{13}$'
                    then (m.value->>'createdAt')::bigint else 0 end) < day_end;
      proof:=recent_count>0;
    elsif p_task_id in ('dm','prime_dm3') then
      select count(*) into recent_count from public.kp_tree_roots r,
         jsonb_each(coalesce(r.document,'{}'::jsonb)) conversation,
         jsonb_each(coalesce(conversation.value->'messages','{}'::jsonb)) m
        where r.branch='dms' and (split_part(conversation.key,'__dm__',1)=nick
          or split_part(conversation.key,'__dm__',2)=nick) and m.value->>'nick'=nick
          and (case when m.value->>'createdAt' ~ '^[0-9]{13}$'
                    then (m.value->>'createdAt')::bigint else 0 end) >= day_start
          and (case when m.value->>'createdAt' ~ '^[0-9]{13}$'
                    then (m.value->>'createdAt')::bigint else 0 end) < day_end;
      proof:=recent_count>=case when p_task_id='prime_dm3' then 3 else 1 end;
    elsif p_task_id in ('transfer','prime_transfer_big') then
      select exists(select 1 from public.kp_ledger l where l.user_id=auth.uid()
        and l.kind='bank_transfer' and l.amount<0
        and l.created_at>=to_timestamp(day_start/1000.0)
        and l.created_at<to_timestamp(day_end/1000.0)
        and (p_task_id='transfer' or -l.amount-coalesce((l.details->>'fee')::bigint,0)>=200)) into proof;
    elsif p_task_id in ('shop','prime_shop_big') then
      select exists(select 1 from public.kp_ledger l where l.user_id=auth.uid()
        and (l.kind in ('business_order_reserve','market_purchase')
          or (l.kind='service_reserve' and l.details->>'service'='delivery'
            and exists(select 1 from public.kp_tree_roots r where r.branch='deliveryCustomOrders'
              and r.document->(l.details->>'order')->>'source'='business')))
        and l.amount<0
        and l.created_at>=to_timestamp(day_start/1000.0)
        and l.created_at<to_timestamp(day_end/1000.0)
        and (p_task_id='shop' or -l.amount>=150)) into proof;
    elsif p_task_id in ('taxi_req','prime_taxi2') then
      select count(*) into recent_count from public.kp_tree_roots r,
        jsonb_each(coalesce(r.document,'{}'::jsonb)) o
        where r.branch='orders' and o.value->>'client'=nick and o.value->>'type'='taxi'
        and (case when o.value->>'createdAt' ~ '^[0-9]{13}$'
          then (o.value->>'createdAt')::bigint else 0 end)>=day_start
        and (case when o.value->>'createdAt' ~ '^[0-9]{13}$'
          then (o.value->>'createdAt')::bigint else 0 end)<day_end;
      proof:=recent_count>=case when p_task_id='prime_taxi2' then 2 else 1 end;
    elsif p_task_id='prime_listing' then
      select exists(select 1 from public.kp_tree_roots r,
        jsonb_each(coalesce(r.document,'{}'::jsonb)) m
        where r.branch='marketplace' and m.value->>'seller'=nick
        and (case when m.value->>'createdAt' ~ '^[0-9]{13}$'
          then (m.value->>'createdAt')::bigint else 0 end)>=day_start
        and (case when m.value->>'createdAt' ~ '^[0-9]{13}$'
          then (m.value->>'createdAt')::bigint else 0 end)<day_end) into proof;
    end if;
    if not proof then raise exception 'Task condition not verified'; end if;
    profile:=jsonb_set(profile,array[claimed_key],claimed||to_jsonb(p_task_id),true);
    profile:=jsonb_set(profile,array['__dailyReward_'||day_key||'_'||p_task_id],'true'::jsonb,true);
  elsif p_kind='once' then
    if profile->>p_task_id='true' then return jsonb_build_object('claimed',false,'reason','already claimed'); end if;
    if p_task_id='rewardedAvatar' then
      proof:=coalesce(profile->>'avatar','')<>'';
      reward:=40;
    elsif p_task_id='rewardedWall' then
      select exists(select 1 from public.kp_tree_roots r,
        jsonb_each(coalesce(r.document->nick,'{}'::jsonb)) m where r.branch='walls') into proof;
      reward:=60;
    else
      raise exception 'One-time reward requires a migrated server-side verification';
    end if;
    if not proof then raise exception 'Task condition not verified'; end if;
    profile:=jsonb_set(profile,array[p_task_id],'true'::jsonb,true);
  else
    raise exception 'Invalid task type';
  end if;
  profile:=jsonb_set(profile,'{taskBalance}',to_jsonb(greatest(0,coalesce((profile->>'taskBalance')::bigint,0))+reward),true);
  whole:=jsonb_set(whole,array[nick],profile,true);
  update public.kp_tree_roots set document=whole,revision=rev+1,updated_at=now() where branch='users';
  insert into public.kp_tree_revisions(branch,revision) values('users',rev+1)
    on conflict(branch) do update set revision=excluded.revision;
  return jsonb_build_object('claimed',true,'reward',reward);
end;
$$;
revoke all on function public.kp_claim_task(text,text) from public,anon;
grant execute on function public.kp_claim_task(text,text) to authenticated;
create or replace function public.kp_my_transactions()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  actor text; legacy jsonb; result jsonb:='[]'::jsonb;
  entry record; meta jsonb; details jsonb; row_time timestamptz;
  raw_time text; kind_name text; who_name text; description text;
  amount_value bigint; action_type text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select nickname into actor from public.kp_profiles where user_id=auth.uid();
  if actor is null then raise exception 'Profile missing'; end if;
  for entry in
    select * from public.kp_ledger l where l.user_id=auth.uid()
    order by coalesce(to_jsonb(l)->>'created_at',to_jsonb(l)->>'createdAt','') desc
    limit 500
  loop
    meta:=to_jsonb(entry); details:=coalesce(meta->'details','{}'::jsonb);
    amount_value:=coalesce((meta->>'amount')::bigint,0);
    kind_name:=coalesce(meta->>'kind','operation');
    action_type:=case when amount_value<0 then 'out' else 'in' end;
    raw_time:=coalesce(meta->>'created_at',meta->>'createdAt','');
    row_time:=null;
    if raw_time ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then row_time:=raw_time::timestamptz;
    elsif raw_time ~ '^[0-9]{12,13}$' then row_time:=to_timestamp(raw_time::numeric/1000); end if;
    who_name:=case kind_name
      when 'bank_transfer' then coalesce(details->>'to',details->>'from','Житель')
      when 'mayor_adjustment' then 'Мэрия'
      when 'duty_fine' then coalesce(details->>'role','КСБ')||' ('||coalesce(details->>'actor','сотрудник')||')'
      when 'market_purchase' then coalesce(details->>'seller','Маркетплейс')
      when 'market_sale' then coalesce(details->>'buyer','Маркетплейс')
      when 'savings_move' then 'Накопительный счёт'
      when 'treasury_withdrawal' then 'Казна мэрии'
      when 'business_promotion' then 'Бизнес'
      when 'market_pin' then 'Маркетплейс'
      else 'Капани' end;
    description:=case kind_name
      when 'bank_transfer' then 'Банковский перевод'||
        case when details ? 'fee' then ' · комиссия '||(details->>'fee')||' ₽' else '' end
      when 'mayor_adjustment' then 'Корректировка баланса мэрией'
      when 'duty_fine' then 'Штраф: '||coalesce(details->>'reason','без причины')
      when 'market_purchase' then 'Покупка через маркет: '||coalesce((select r.document->(details->>'listingId')->>'title' from public.kp_tree_roots r where r.branch='marketplace'),'товар')
      when 'market_sale' then 'Продажа через маркет: '||coalesce((select r.document->(details->>'listingId')->>'title' from public.kp_tree_roots r where r.branch='marketplace'),'товар')
      when 'savings_move' then case when details->>'direction'='deposit'
        then 'Пополнение накопительного счёта' else 'Снятие с накопительного счёта' end
      when 'treasury_withdrawal' then 'Вывод из казны'
      when 'business_promotion' then 'Продвижение бизнеса'
      when 'market_pin' then 'Закрепление объявления'
      when 'task_withdrawal' then 'Вывод средств заданий'
      when 'service_reserve' then 'Оплата '||case details->>'service'
        when 'taxi' then 'такси' when 'delivery' then 'доставки' when 'hospital' then 'приёма в больнице'
        else 'услуги' end||case when details->>'service'='delivery' then
          ' — '||coalesce((select r.document->(details->>'order')->>'items' from public.kp_tree_roots r where r.branch='deliveryCustomOrders'),'заказ')
          when details->>'service'='hospital' then ' — '||coalesce((select r.document->'appointments'->(details->>'order')->>'serviceName' from public.kp_tree_roots r where r.branch='hospital'),'приём')
          else '' end||' (зарезервирована)'
      when 'service_refund' then 'Возврат оплаты услуги'
      when 'service_payout' then 'Оплата выполненной услуги'
      when 'business_order_reserve' then 'Заказ в «'||coalesce(
        (select r.document->(details->>'bizId')->>'name' from public.kp_tree_roots r where r.branch='businesses'),
        'бизнесе')||'»: '||coalesce((
        select string_agg(coalesce(product.value->>'name','товар')||' × '||coalesce(product.value->>'qty','1'),', ')
        from public.kp_tree_roots r
        cross join lateral jsonb_each(coalesce(r.document->(details->>'bizId'),'{}'::jsonb)) as orders(order_id,order_data)
        cross join lateral jsonb_array_elements(coalesce(orders.order_data->'items','[]'::jsonb)) as product(value)
        where r.branch='bizOrders'
          and (md5(orders.order_id||':biz-reserve'))::uuid::text=meta->>'operation_id'
      ),'товары')||' (оплата зарезервирована)'
      when 'business_order_refund' then 'Возврат оплаты заказа в бизнесе'
      when 'business_sale' then 'Продажа товара'
      when 'casino_deposit' then 'Пополнение игрового счёта'
      when 'casino_withdraw' then 'Вывод с игрового счёта'
      when 'event_reserve' then 'Резерв для мероприятия: '||coalesce(details->>'title','событие')
      when 'event_bet' then 'Ставка на мероприятие'
      when 'event_result' then 'Выигрыш по ставке'
      when 'event_reserve_return' then 'Возврат резерва мероприятия'
      when 'subscription_buy' then 'Оплата подписки '||coalesce(details->>'plan','')
      when 'subscription_gift' then 'Подарок подписки '||coalesce(details->>'plan','')
      when 'business_deposit' then 'Пополнение счёта бизнеса'
      when 'business_withdraw' then 'Вывод со счёта бизнеса'
      when 'business_auto_salary' then 'Зарплата в бизнесе'
      when 'assistant_salary_out' then 'Выплата помощнику'
      when 'assistant_salary_in' then 'Зарплата помощника'
      when 'civic_fee' then 'Оплата услуги мэрии: '||coalesce(details->>'kind','заявка')
      when 'civic_refund' then 'Возврат оплаты услуги мэрии'
      when 'janitor_reward' then 'Оплата работы уборщика'
      when 'rental_payment' then 'Аренда здания'
      when 'savings_interest' then 'Начисление процентов на накопления'
      else kind_name end;
    result:=result||jsonb_build_array(jsonb_build_object(
      'id',coalesce(meta->>'operation_id',''),'type',action_type,'amt',abs(amount_value),
      'who',who_name,'desc',description,'kind',kind_name,'details',details,
      'ts',case when row_time is not null then to_char(row_time at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') else '' end,
      'date',case when row_time is not null then to_char(row_time at time zone 'Europe/Moscow','DD.MM.YYYY') else '' end,
      'time',case when row_time is not null then to_char(row_time at time zone 'Europe/Moscow','HH24:MI') else '' end
    ));
  end loop;
  select document->actor->'txlog' into legacy from public.kp_tree_roots where branch='users';
  if jsonb_typeof(legacy)='object' then
    result:=result||coalesce((select jsonb_agg(value) from jsonb_each(legacy)),'[]'::jsonb);
  end if;
  return result;
end;
$$;
revoke all on function public.kp_my_transactions() from public,anon;
grant execute on function public.kp_my_transactions() to authenticated;
commit;
