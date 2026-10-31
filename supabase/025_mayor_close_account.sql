-- Mayor account closure. Apply after 024. Preserves wallet and ledger records.
begin;

create or replace function public.kp_mayor_close_account(p_target text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor text;
  target_uid uuid;
  users_doc jsonb;
  rev bigint;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select nickname into actor from public.kp_profiles where user_id=auth.uid();
  if actor is distinct from 'Кайон' then raise exception 'Mayor access required'; end if;
  if p_target is null or length(p_target) not between 2 and 120 or p_target='Кайон' then
    raise exception 'Invalid target account';
  end if;
  select user_id into target_uid from public.kp_profiles where nickname=p_target for update;
  if target_uid is null then raise exception 'Account not found'; end if;
  select document,revision into users_doc,rev from public.kp_tree_roots
    where branch='users' for update;
  if users_doc is null or not users_doc ? p_target then
    raise exception 'Account profile not found';
  end if;

  -- Existing access tokens can outlive an Auth ban. Removing kp_profiles also
  -- makes protected RPCs fail to resolve the former account immediately.
  update auth.users set banned_until='infinity'::timestamptz,updated_at=now()
    where id=target_uid;
  delete from public.kp_profiles where user_id=target_uid;
  update public.kp_tree_roots
    set document=users_doc-p_target,revision=rev+1,updated_at=now()
    where branch='users';
  insert into public.kp_tree_revisions(branch,revision) values('users',rev+1)
    on conflict(branch) do update set revision=excluded.revision;
  return jsonb_build_object('ok',true,'nick',p_target,'closed',true);
end;
$$;
revoke all on function public.kp_mayor_close_account(text) from public,anon;
grant execute on function public.kp_mayor_close_account(text) to authenticated;

create or replace function public.kp_mayor_review_close_request(p_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor text;
  requests jsonb;
  request_doc jsonb;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select nickname into actor from public.kp_profiles where user_id=auth.uid();
  if actor is distinct from 'Кайон' then raise exception 'Mayor access required'; end if;
  if length(coalesce(p_id,'')) not between 8 and 100 then raise exception 'Invalid request ID'; end if;
  select document into requests from public.kp_tree_roots
    where branch='policeRequests' for update;
  request_doc:=requests->p_id;
  if request_doc is null or request_doc->>'status'<>'pending'
     or request_doc->>'type' not in ('delete','freeze') then
    raise exception 'Pending closure request not found';
  end if;
  result:=public.kp_mayor_close_account(request_doc->>'target');
  request_doc:=request_doc||jsonb_build_object('status','approved',
    'reviewedAt',(extract(epoch from clock_timestamp())*1000)::bigint);
  perform public.kp_v8_put('policeRequests',jsonb_set(requests,array[p_id],request_doc,true));
  return result||jsonb_build_object('request',p_id);
end;
$$;
revoke all on function public.kp_mayor_review_close_request(text) from public,anon;
grant execute on function public.kp_mayor_review_close_request(text) to authenticated;

commit;
