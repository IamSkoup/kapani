-- Kapani 021. Apply only after migrations 001-020.
-- Self-resignation is a protected, authenticated operation. Neither the
-- browser nor kp_profile_patch may edit job/employments directly.
begin;

create or replace function public.kp_quit_job(p_employment_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor text;
  users_doc jsonb;
  profile jsonb;
  jobs jsonb;
  remaining jsonb;
  target_job jsonb;
  role_name text;
  old_municipal text;
  new_municipal text;
  display_role text;
  business_id text;
  businesses_doc jsonb;
  business_doc jsonb;
  member jsonb;
  is_municipal boolean;
  has_employment boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select nickname into actor from public.kp_profiles where user_id=auth.uid();
  if actor is null then raise exception 'Profile not found'; end if;
  if p_employment_id is null or length(p_employment_id) not between 7 and 140 then
    raise exception 'Invalid employment ID';
  end if;

  -- Keep the same lock order as other employment RPCs: users, businesses.
  select document into users_doc from public.kp_tree_roots where branch='users' for update;
  profile := users_doc->actor;
  if profile is null then raise exception 'User data unavailable'; end if;
  jobs := case jsonb_typeof(profile->'employments')
    when 'array' then profile->'employments'
    when 'object' then coalesce((select jsonb_agg(value) from jsonb_each(profile->'employments')), '[]'::jsonb)
    else '[]'::jsonb end;

  select item into target_job from jsonb_array_elements(jobs) as employment(item)
  where item->>'id'=p_employment_id limit 1;

  is_municipal := left(p_employment_id,5)='muni_';
  if is_municipal then
    role_name := substring(p_employment_id from 6);
    if role_name='' or (
      not (coalesce(target_job->>'type','municipal')='municipal'
           and target_job->>'role'=role_name)
      and coalesce(profile->>'job','Житель')<>role_name
    ) then raise exception 'Municipal employment not found'; end if;
  elsif left(p_employment_id,4)='biz_' then
    business_id := substring(p_employment_id from 5);
    if business_id='' then raise exception 'Invalid business ID'; end if;
    select document into businesses_doc from public.kp_tree_roots where branch='businesses' for update;
    business_doc := businesses_doc->business_id;
    member := business_doc->'employees'->actor;
    if member is null and (target_job is null or target_job->>'type'<>'business'
      or target_job->>'bizId'<>business_id) then
      raise exception 'Business employment not found';
    end if;
    role_name := coalesce(target_job->>'role',member->>'roleName',member->>'role','Сотрудник');
    if member is not null then
      business_doc := business_doc #- array['employees',actor];
    end if;
  else
    raise exception 'Unsupported employment ID';
  end if;

  select coalesce(jsonb_agg(item),'[]'::jsonb) into remaining
  from jsonb_array_elements(jobs) as employment(item)
  where item->>'id' is distinct from p_employment_id;

  old_municipal := coalesce(profile->>'job','Житель');
  select item->>'role' into new_municipal
  from jsonb_array_elements(remaining) as employment(item)
  where item->>'type'='municipal' and nullif(item->>'role','') is not null limit 1;
  if old_municipal<>'Житель' and (not is_municipal or old_municipal<>role_name) then
    new_municipal := old_municipal;
  else
    new_municipal := coalesce(new_municipal,'Житель');
  end if;

  display_role := profile->>'displayJob';
  if not exists(select 1 from jsonb_array_elements(remaining) as employment(item)
    where item->>'role'=display_role) then
    select item->>'role' into display_role from jsonb_array_elements(remaining) as employment(item)
    where nullif(item->>'role','') is not null limit 1;
    if display_role is null and new_municipal<>'Житель' then display_role:=new_municipal; end if;
  end if;

  profile := profile || jsonb_build_object(
    'employments',remaining, 'job',new_municipal, 'displayJob',display_role
  );
  if is_municipal and new_municipal='Житель' then
    profile := profile || jsonb_build_object('jobApplicationStatus',null,'appliedJob',null);
  end if;
  if business_id is not null and profile->>'employerBizId'=business_id then
    profile := profile || jsonb_build_object('employerBizId',null);
  end if;
  if role_name in ('Водитель','Доставщик') and not exists(
    select 1 from jsonb_array_elements(remaining) as employment(item)
    where item->>'role' in ('Водитель','Доставщик')
  ) then profile := profile || jsonb_build_object('vehicle',''); end if;
  if role_name='Уборщик' and not exists(
    select 1 from jsonb_array_elements(remaining) as employment(item)
    where item->>'role'='Уборщик'
  ) then
    profile := profile || jsonb_build_object(
      'janitorTaskDate','','janitorSubmissionId','','janitorSubmissionStatus','',
      'janitorProof','','janitorComment',''
    );
  end if;
  if role_name='Рекламщик' then
    profile := profile || jsonb_build_object('advertiserSalaryPaidThroughWeek',
      to_char(date_trunc('week',now() at time zone 'Europe/Moscow'),'YYYY-MM-DD'));
  end if;
  if role_name in ('Полицейский','КСБ','Охранник')
    and new_municipal not in ('Полицейский','КСБ','Охранник')
    and not exists(select 1 from jsonb_array_elements(remaining) as employment(item)
      where item->>'role' in ('Полицейский','КСБ','Охранник')) then
    profile := profile || jsonb_build_object('securityBadge',null);
  end if;

  perform public.kp_v8_put('users',jsonb_set(users_doc,array[actor],profile,true));
  if business_id is not null and member is not null then
    perform public.kp_v8_put('businesses',
      jsonb_set(businesses_doc,array[business_id],business_doc,true));
  end if;
  return jsonb_build_object('ok',true,'employments',remaining,
    'job',new_municipal,'displayJob',display_role);
end;
$$;

revoke all on function public.kp_quit_job(text) from public,anon;
grant execute on function public.kp_quit_job(text) to authenticated;
commit;
