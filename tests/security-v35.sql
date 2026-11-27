-- Run on a disposable database after 035. No lasting test data.
begin;
do $test$
declare q text:=repeat('f',64); i int;
begin
  if has_function_privilege('anon','public.kp_consume_signup_attempt_v35(text)','EXECUTE')
     or has_function_privilege('authenticated','public.kp_consume_signup_attempt_v35(text)','EXECUTE')
     or not has_function_privilege('service_role','public.kp_consume_signup_attempt_v35(text)','EXECUTE') then
    raise exception 'Unexpected signup quota ACL';
  end if;
  if has_function_privilege('anon','public.kp_nickname_reserved_v35(text)','EXECUTE')
     or has_function_privilege('authenticated','public.kp_nickname_reserved_v35(text)','EXECUTE') then
    raise exception 'Unexpected identity lookup ACL';
  end if;
  if has_table_privilege('anon','public.kp_identity_reservations_v35','SELECT')
     or has_table_privilege('authenticated','public.kp_identity_reservations_v35','INSERT') then
    raise exception 'Unexpected identity table ACL';
  end if;
  if not exists(select 1 from public.kp_profiles p
    join public.kp_identity_reservations_v35 r using(nickname)
    where p.nickname='Кайон' and p.user_id=r.user_id) then
    raise exception 'Mayor identity not pinned';
  end if;
  delete from public.kp_signup_attempts where ip_hash=q;
  for i in 1..5 loop
    if not public.kp_consume_signup_attempt_v35(q) then
      raise exception 'Signup quota rejected attempt %',i;
    end if;
  end loop;
  if public.kp_consume_signup_attempt_v35(q) then
    raise exception 'Signup quota allowed sixth attempt';
  end if;
  if not exists(select 1 from pg_policies where schemaname='storage'
      and tablename='objects' and policyname='kp_media_no_cross_user_listing_v35'
      and permissive='RESTRICTIVE') then
    raise exception 'Storage listing guard missing';
  end if;
end $test$;
rollback;
