-- Apply after 024. Migration 025 is optional; this installs actual deletion.
-- Run after a database backup. The deleted wallet and ledger are archived for audit.
begin;

create table if not exists public.kp_deleted_account_audit (
  user_id uuid primary key,
  nickname text not null,
  profile jsonb not null,
  wallet jsonb,
  ledger jsonb not null,
  deleted_at timestamptz not null default now()
);
alter table public.kp_deleted_account_audit enable row level security;
revoke all on public.kp_deleted_account_audit from public,anon,authenticated;

create or replace function public.kp_mayor_delete_account(p_target text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor text;
  target_uid uuid;
  users_doc jsonb;
  old_profile jsonb;
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
  old_profile:=users_doc->p_target;
  if old_profile is null then raise exception 'Account profile not found'; end if;
  if exists(select 1 from jsonb_each(coalesce(
      (select document from public.kp_tree_roots where branch='orders'),'{}'::jsonb)) as entry
      where (entry.value->>'client'=p_target or entry.value->>'worker'=p_target)
        and coalesce(entry.value->>'status','pending') not in
          ('paid','cancelled','completed','done','rejected'))
     or exists(select 1 from jsonb_each(coalesce(
      (select document from public.kp_tree_roots where branch='deliveryCustomOrders'),'{}'::jsonb)) as entry
      where (entry.value->>'client'=p_target or entry.value->>'worker'=p_target)
        and coalesce(entry.value->>'status','waiting') not in
          ('paid','cancelled','completed','done','rejected')) then
    raise exception 'Finish or cancel active orders before deleting this account';
  end if;

  insert into public.kp_deleted_account_audit(user_id,nickname,profile,wallet,ledger)
  values(target_uid,p_target,old_profile - 'passwordHash' - 'passwordHashSalt',
    (select to_jsonb(w) from public.kp_wallets w where w.user_id=target_uid),
    (select coalesce(jsonb_agg(to_jsonb(l)),'[]'::jsonb)
       from public.kp_ledger l where l.user_id=target_uid));

  -- These records are retained in the private audit archive above. Explicit
  -- deletes also work when the existing foreign keys do not cascade.
  delete from public.kp_ledger where user_id=target_uid;
  delete from public.kp_wallets where user_id=target_uid;
  delete from public.kp_profiles where user_id=target_uid;
  delete from auth.users where id=target_uid;
  if not found then raise exception 'Auth account not found'; end if;

  update public.kp_tree_roots
    set document=users_doc-p_target,revision=rev+1,updated_at=now()
    where branch='users';
  insert into public.kp_tree_revisions(branch,revision) values('users',rev+1)
    on conflict(branch) do update set revision=excluded.revision;
  return jsonb_build_object('ok',true,'nick',p_target,'deleted',true);
end;
$$;
revoke all on function public.kp_mayor_delete_account(text) from public,anon;
grant execute on function public.kp_mayor_delete_account(text) to authenticated;

create or replace function public.kp_police_request_delete_v26(
  p_id text, p_target text, p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor text:=public.kp_v8_actor();
  users_doc jsonb;
  requests jsonb;
  request_doc jsonb;
begin
  if actor is null or not (public.kp_v8_role(actor,'Полицейский')
      or public.kp_v8_role(actor,'КСБ')) then
    raise exception 'Police access required';
  end if;
  if length(coalesce(p_id,'')) not between 8 and 100
     or length(trim(coalesce(p_reason,''))) not between 5 and 1200
     or p_target is null or p_target='Кайон' then
    raise exception 'Invalid deletion request';
  end if;
  select document into users_doc from public.kp_tree_roots
    where branch='users' for update;
  if users_doc->p_target is null
     or not exists(select 1 from public.kp_profiles where nickname=p_target) then
    raise exception 'Account not found';
  end if;
  insert into public.kp_tree_roots(branch) values('policeRequests')
    on conflict do nothing;
  select document into requests from public.kp_tree_roots
    where branch='policeRequests' for update;
  request_doc:=requests->p_id;
  if request_doc is not null then
    if request_doc->>'officer'=actor and request_doc->>'target'=p_target
       and request_doc->>'type'='delete' then return request_doc; end if;
    raise exception 'Request ID already used';
  end if;
  request_doc:=jsonb_build_object('id',p_id,'kind','police',
    'type','delete','officer',actor,'from',actor,'target',p_target,
    'reason',trim(p_reason),'status','pending',
    'createdAt',(extract(epoch from clock_timestamp())*1000)::bigint);
  perform public.kp_v8_put('policeRequests',jsonb_set(requests,array[p_id],request_doc,true));
  perform public.kp_v8_notify('Кайон','Заявка на удаление аккаунта '||p_target,
    'system','police_delete_'||p_id);
  return request_doc;
end;
$$;
revoke all on function public.kp_police_request_delete_v26(text,text,text) from public,anon;
grant execute on function public.kp_police_request_delete_v26(text,text,text) to authenticated;

create or replace function public.kp_mayor_review_delete_request(p_id text)
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
    raise exception 'Pending deletion request not found';
  end if;
  result:=public.kp_mayor_delete_account(request_doc->>'target');
  request_doc:=request_doc||jsonb_build_object('status','approved',
    'reviewedAt',(extract(epoch from clock_timestamp())*1000)::bigint);
  perform public.kp_v8_put('policeRequests',jsonb_set(requests,array[p_id],request_doc,true));
  return result||jsonb_build_object('request',p_id);
end;
$$;
revoke all on function public.kp_mayor_review_delete_request(text) from public,anon;
grant execute on function public.kp_mayor_review_delete_request(text) to authenticated;

do $$ begin
  if to_regprocedure('public.kp_mayor_close_account(text)') is not null then
    revoke execute on function public.kp_mayor_close_account(text) from authenticated;
  end if;
  if to_regprocedure('public.kp_mayor_review_close_request(text)') is not null then
    revoke execute on function public.kp_mayor_review_close_request(text) from authenticated;
  end if;
end $$;
commit;
