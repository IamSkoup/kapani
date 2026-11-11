-- Apply after 001-029. Review legacy scooter exams and pay advertiser wages
-- through authenticated, server-owned operations only.
begin;

-- New scooter requests are reviewed by kp_civic_v8. This endpoint is only for
-- older, exam-based requests that exist exclusively inside users/<nickname>.
create or replace function public.kp_mayor_review_scooter_legacy(
  p_target text, p_approve boolean
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor text:=public.kp_v8_actor();
  users_doc jsonb;
  profile jsonb;
  application jsonb;
  licenses_doc jsonb;
  license_info jsonb;
  reviewed_ms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
begin
  if actor is distinct from 'Кайон' then raise exception 'Mayor access required'; end if;
  if p_target is null or length(p_target) not between 2 and 120 or p_approve is null then
    raise exception 'Invalid scooter review';
  end if;
  select document into users_doc from public.kp_tree_roots where branch='users' for update;
  profile:=users_doc->p_target;
  if profile is null then raise exception 'Resident not found'; end if;
  application:=profile->'scooterLicenseApplication';
  if application is null or application->>'status'<>'pending' then
    raise exception 'Scooter application is no longer pending';
  end if;
  if application->>'kind'='scooter' then
    raise exception 'Use civic review for this application';
  end if;
  if p_approve and (
    profile->'scooterExam'->>'status' is distinct from 'passed'
    or coalesce((profile->'scooterExam'->>'score')::integer,0)<4
  ) then raise exception 'Scooter exam has not been passed'; end if;

  application:=application||jsonb_build_object(
    'status',case when p_approve then 'approved' else 'rejected' end,
    'reviewedAt',reviewed_ms,'reviewedBy',actor
  );
  profile:=jsonb_set(profile,'{scooterLicenseApplication}',application,true);
  if p_approve then
    license_info:=coalesce(profile->'licenses','{}'::jsonb)||
      jsonb_build_object('scooter',true,'scooterIssuedAt',reviewed_ms);
    profile:=jsonb_set(profile,'{licenses}',license_info,true);
    insert into public.kp_tree_roots(branch) values('licenses') on conflict do nothing;
    select document into licenses_doc from public.kp_tree_roots
      where branch='licenses' for update;
    perform public.kp_v8_put('licenses',
      public.kp_tree_set_deep(licenses_doc,array[p_target,'scooter'],'true'::jsonb));
  end if;
  perform public.kp_v8_put('users',jsonb_set(users_doc,array[p_target],profile,true));
  perform public.kp_v8_notify(p_target,
    case when p_approve then 'Права на скутер одобрены мэрией.'
      else 'Мэрия отказала в выдаче прав на скутер.' end,
    'system','scooter_review_'||coalesce(application->>'id',p_target));
  return jsonb_build_object('ok',true,'status',application->>'status','target',p_target);
end;
$$;
revoke all on function public.kp_mayor_review_scooter_legacy(text,boolean)
  from public,anon,authenticated;
grant execute on function public.kp_mayor_review_scooter_legacy(text,boolean)
  to authenticated;

-- The first authenticated visit starts the advertiser's first payable week.
-- Each subsequent visit settles completed weeks once, using signed-up user
-- records and the protected ledger. Browser input cannot choose the amount,
-- referral count, recipient or week to settle.
create or replace function public.kp_advertiser_weekly_salary_v30()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor text:=public.kp_v8_actor();
  users_doc jsonb;
  profile jsonb;
  stats_doc jsonb;
  next_week date;
  current_week date:=date_trunc('week',clock_timestamp() at time zone 'Europe/Moscow')::date;
  start_ms bigint;
  end_ms bigint;
  reset_ms bigint;
  referrals integer;
  current_referrals integer;
  salary bigint;
  total_paid bigint:=0;
  settled_weeks integer:=0;
  operation uuid;
  result jsonb;
begin
  if actor is null then raise exception 'Authentication required'; end if;
  select document into users_doc from public.kp_tree_roots where branch='users' for update;
  profile:=users_doc->actor;
  if profile is null then raise exception 'Resident not found'; end if;
  if not public.kp_v8_role(actor,'Рекламщик') then
    return jsonb_build_object('active',false);
  end if;
  select document into stats_doc from public.kp_tree_roots where branch='advertiserStats';
  reset_ms:=coalesce((stats_doc->actor->>'resetAt')::bigint,0);

  -- This marker is server-owned. Never retrospectively award wages for
  -- unknown employment periods when the marker is first initialized.
  next_week:=coalesce(
    nullif(profile->>'advertiserSalaryNextWeek','')::date,
    current_week
  );
  if next_week>current_week then raise exception 'Invalid advertiser salary week'; end if;
  if current_week-next_week>735 then raise exception 'Salary history needs mayor review'; end if;

  while next_week<current_week loop
    start_ms:=(extract(epoch from (next_week::timestamp at time zone 'Europe/Moscow'))*1000)::bigint;
    end_ms:=(extract(epoch from ((next_week+7)::timestamp at time zone 'Europe/Moscow'))*1000)::bigint;
    select count(*) into referrals
      from jsonb_each(coalesce(users_doc,'{}'::jsonb)) invited
      where invited.key<>actor and invited.value->>'invitedBy'=actor
        and exists(select 1 from public.kp_profiles p where p.nickname=invited.key)
        and coalesce((invited.value->>'referralCreatedAt')::bigint,0)>=start_ms
        and (invited.value->>'referralCreatedAt')::bigint<end_ms
        and (invited.value->>'referralCreatedAt')::bigint>reset_ms;
    salary:=case when referrals>=4 then 3900+(referrals-4)*500 else 0 end;
    if salary>0 then
      operation:=(md5('advertiser_salary:'||actor||':'||next_week::text))::uuid;
      if not exists(select 1 from public.kp_ledger where operation_id=operation) then
        perform public.kp_v8_money(actor,salary,operation,'advertiser_weekly_salary',
          jsonb_build_object('week',next_week::text,'referrals',referrals,'base',3900,'extra',greatest(0,referrals-4)*500));
        total_paid:=total_paid+salary;
        perform public.kp_v8_notify(actor,
          'Зарплата рекламщика за неделю '||next_week::text||': +'||
          salary::text||' ₽ ('||referrals::text||' приглашённых).',
          'money','advertiser_salary_'||next_week::text);
      end if;
    end if;
    next_week:=next_week+7;
    settled_weeks:=settled_weeks+1;
  end loop;

  start_ms:=(extract(epoch from (current_week::timestamp at time zone 'Europe/Moscow'))*1000)::bigint;
  end_ms:=(extract(epoch from ((current_week+7)::timestamp at time zone 'Europe/Moscow'))*1000)::bigint;
  select count(*) into current_referrals
    from jsonb_each(coalesce(users_doc,'{}'::jsonb)) invited
    where invited.key<>actor and invited.value->>'invitedBy'=actor
      and exists(select 1 from public.kp_profiles p where p.nickname=invited.key)
      and coalesce((invited.value->>'referralCreatedAt')::bigint,0)>=start_ms
      and (invited.value->>'referralCreatedAt')::bigint<end_ms
      and (invited.value->>'referralCreatedAt')::bigint>reset_ms;

  -- kp_v8_money updates the same root: refresh it before adding the marker
  -- so salary payouts, new balances and notifications are all retained.
  select document into users_doc from public.kp_tree_roots where branch='users';
  profile:=users_doc->actor;
  profile:=profile||jsonb_build_object(
    'advertiserSalaryNextWeek',next_week::text,
    'advertiserSalaryPaidThroughWeek',(next_week-7)::text,
    'totalEarned',coalesce((profile->>'totalEarned')::bigint,0)+total_paid
  );
  perform public.kp_v8_put('users',jsonb_set(users_doc,array[actor],profile,true));
  result:=jsonb_build_object('active',true,'week',current_week::text,
    'referrals',current_referrals,'required',4,'base',3900,'bonusPerExtra',500,
    'projected',case when current_referrals>=4 then 3900+(current_referrals-4)*500 else 0 end,
    'paid',total_paid,'settledWeeks',settled_weeks);
  return result;
end;
$$;
revoke all on function public.kp_advertiser_weekly_salary_v30()
  from public,anon,authenticated;
grant execute on function public.kp_advertiser_weekly_salary_v30()
  to authenticated;
commit;
