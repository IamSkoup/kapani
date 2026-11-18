-- Run against a seeded Kapani database after migrations 032–033. All fixture changes are rolled back.
begin;
do $test$
declare
  mayor uuid; worker uuid:=gen_random_uuid(); officer uuid:=gen_random_uuid();
  event uuid:=gen_random_uuid(); stake uuid:=gen_random_uuid(); transfer uuid:=gen_random_uuid();
  gift uuid:=gen_random_uuid(); job_date date:=(date_trunc('week',now() at time zone 'Europe/Moscow')::date-7);
  data jsonb; week_row jsonb; start_balance bigint; paid bigint; failed boolean;
begin
  select user_id into strict mayor from public.kp_profiles where nickname='Кайон';
  insert into auth.users(id) values(worker),(officer);
  insert into public.kp_profiles(user_id,nickname) values(worker,'TempJanitorV39'),(officer,'TempOfficerV39');
  insert into public.kp_wallets(user_id,balance) values(worker,20000),(officer,20000)
    on conflict(user_id) do update set balance=excluded.balance;
  update public.kp_tree_roots set document=document||
    '{"TempJanitorV39":{"nick":"TempJanitorV39","accountVerified":true,"job":"Уборщик","balance":20000},
      "TempOfficerV39":{"nick":"TempOfficerV39","accountVerified":true,"job":"КСБ","balance":20000}}'
    where branch='users';

  perform set_config('request.jwt.claim.sub',worker::text,true);
  perform public.kp_profile_patch('{"profileDescription":"Проверка описания"}');
  failed:=false;
  begin perform public.kp_update_license_v39('TempOfficerV39','bike',true);
  exception when others then failed:=sqlerrm='License staff access required';end;
  if not failed then raise exception 'Resident was allowed to change a license';end if;
  perform public.kp_bank_transfer('TempOfficerV39',110,transfer);
  perform public.kp_bank_transfer('TempOfficerV39',110,transfer);
  if (public.kp_tree_access('read','users/TempJanitorV39/profileDescription')#>>'{value}')<>'Проверка описания' then raise exception 'Own description missing';end if;
  data:=public.kp_civic_v8('submit','janitor','temp-v39-report',jsonb_build_object('photo','https://example.test/photo'));
  if data->>'status'<>'pending' then raise exception 'Report was not submitted';end if;
  select balance into start_balance from public.kp_wallets where user_id=worker;

  perform set_config('request.jwt.claim.sub',officer::text,true);
  if not coalesce(public.kp_tree_access('read','users/TempOfficerV39/notifications')#>'{value}' ? ('transfer_'||transfer),false) then raise exception 'Transfer inbox item missing';end if;
  if (public.kp_tree_access('read','users/TempJanitorV39')#>>'{value,profileDescription}')<>'Проверка описания' then raise exception 'Public description missing';end if;
  perform public.kp_update_license_v39('TempJanitorV39','bike',true);
  if public.kp_license_status('TempJanitorV39')->>'bike' is distinct from 'true' then raise exception 'Staff license write missing';end if;
  perform public.kp_update_license_v39('TempJanitorV39','bike',false);
  if public.kp_license_status('TempJanitorV39')->>'bike' is distinct from 'false' then raise exception 'Staff license revoke missing';end if;
  perform public.kp_subscription_v10('gift',gift,'plus','TempJanitorV39');
  perform public.kp_subscription_v10('gift',gift,'plus','TempJanitorV39');

  perform public.kp_civic_v8('submit','police','temp-v39-freeze',
    '{"type":"freeze","target":"TempJanitorV39","reason":"Fixture for legacy freeze"}');
  perform set_config('request.jwt.claim.sub',mayor::text,true);
  failed:=false;
  begin perform public.kp_mayor_review_delete_request('temp-v39-freeze');
  exception when others then failed:=sqlerrm='Pending deletion request not found';end;
  if not failed then raise exception 'Account deletion accepted a freeze request';end if;
  perform public.kp_civic_v8('approve','police','temp-v39-freeze','{}');
  if not exists(select 1 from public.kp_profiles where user_id=worker)
    or (public.kp_tree_access('read','users/TempJanitorV39')#>>'{value,accountFrozen}') is distinct from 'true' then
    raise exception 'Freeze did not preserve the account';end if;
  update public.kp_tree_roots set document=jsonb_set(document,'{TempJanitorV39,accountFrozen}','false') where branch='users';
  data:=public.kp_civic_v8('approve','janitor','temp-v39-report','{}');
  if data->>'status'<>'approved' or (select balance from public.kp_wallets where user_id=worker)<>start_balance then
    raise exception 'Report approval must not pay wages';
  end if;
  for i in 0..4 loop
    update public.kp_tree_roots set document=document||jsonb_build_object('temp-v39-week-'||i,
      jsonb_build_object('worker','TempJanitorV39','status','approved','date',job_date+i))
      where branch='janitorSubmissions';
  end loop;
  select e into week_row from jsonb_array_elements(public.kp_janitor_weeks_v39()) e
    where e->>'worker'='TempJanitorV39' and e->>'week'=job_date::text;
  if coalesce((week_row->>'approved')::int,0)<>5 then raise exception 'Weekly count incorrect';end if;
  perform public.kp_pay_janitor_week_v39('TempJanitorV39',job_date,530);
  perform public.kp_pay_janitor_week_v39('TempJanitorV39',job_date,530);
  select balance into paid from public.kp_wallets where user_id=worker;
  if paid-start_balance<>530 then raise exception 'Weekly payout missing or replayed';end if;
  insert into public.kp_v8_events(id,title,kind,sides,closes_at,budget)
    values(event,'Temp test','sport','[{"name":"А","odds":1.5},{"name":"Б","odds":2}]',now()+interval '1 day',10000);

  perform set_config('request.jwt.claim.sub',worker::text,true);
  perform public.kp_events_v8('bet',stake,jsonb_build_object('event',event,'side',0,'stake',2500));
  perform public.kp_events_v8('bet',stake,jsonb_build_object('event',event,'side',0,'stake',2500));
  failed:=false;
  begin perform public.kp_events_v8('bet',gen_random_uuid(),jsonb_build_object('event',event,'side',1,'stake',100));
  exception when others then failed:=sqlerrm='Already bet on this event';end;
  if not failed then raise exception 'Second bet accepted';end if;
  data:=public.kp_chat_read_v39('dms/TempJanitorV39__dm__TempOfficerV39/messages',80);
  if data#>>array['gift_'||gift,'subscriptionGift','plan'] is distinct from 'plus' then
    raise exception 'Gift not visible in chat';
  end if;
  data:=public.kp_chat_read_v39('dmIndex/TempJanitorV39');
  if data#>>'{TempOfficerV39,latest,subscriptionGift,plan}' is distinct from 'plus' then raise exception 'Gift preview missing';end if;
  perform public.kp_chat_mark_dm_read_v39('TempOfficerV39');
  data:=public.kp_chat_read_v39('dmIndex/TempJanitorV39');
  if data#>>'{TempOfficerV39,unread}' is distinct from 'false' then raise exception 'Mark read failed';end if;
  data:=public.kp_casino_v8('view');
  if data->>'balance' is distinct from '0' or exists(select 1 from public.kp_v8_casino_accounts where user_id=worker) then
    raise exception 'Casino view made a write';
  end if;
  perform public.kp_profile_customization_v14('{"avatarFrame":"forest_moss","profileBgEffect":"nature_meadow","chatBubbleStyle":"forest_moss"}');
  data:=public.kp_tree_access('read','users/TempJanitorV39');
  if data#>>'{value,profileBgEffect}' is distinct from 'nature_meadow' then raise exception 'Skin did not persist';end if;
end;
$test$;

rollback;
