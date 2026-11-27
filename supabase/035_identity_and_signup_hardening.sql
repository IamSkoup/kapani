-- Identity reservations, atomic signup quota, and Storage listing hardening.
-- Apply to the existing Kapani database AFTER 034. Back up first.
-- The current mayor UUID must be verified by the operator before running.
begin;
lock table public.kp_profiles in share row exclusive mode;

-- Legacy conversations use nickname-delimited keys. Fail without modifying
-- anything if ambiguous existing identities require a manual data migration.
do $check$
begin
  if (select count(*) from public.kp_profiles where nickname='Кайон') <> 1 then
    raise exception 'Verify the existing mayor identity before applying 035';
  end if;
  if exists(select 1 from public.kp_profiles where strpos(nickname,'__dm__')>0) then
    raise exception 'Legacy ambiguous nickname: resolve identities before applying 035';
  end if;
  if exists(
    select 1 from public.kp_tree_roots r
    cross join lateral jsonb_object_keys(coalesce(r.document,'{}'::jsonb)) k(key)
    where r.branch='dms'
      and (length(k.key)-length(replace(k.key,'__dm__',''))<>length('__dm__')
        or split_part(k.key,'__dm__',1)='' or split_part(k.key,'__dm__',2)='')
  ) then
    raise exception 'Legacy ambiguous DM key: review existing conversations before applying 035';
  end if;
end $check$;

-- Keep an immutable nickname-to-UUID binding, including after account deletion.
-- A NULL UUID means a legacy name with no verifiable current account. It is
-- permanently reserved rather than reassigned to a new identity.
create table if not exists public.kp_identity_reservations_v35(
  nickname text primary key,
  user_id uuid,
  reserved_at timestamptz not null default now()
);
alter table public.kp_identity_reservations_v35 enable row level security;
revoke all on public.kp_identity_reservations_v35 from public,anon,authenticated;
insert into public.kp_identity_reservations_v35(nickname,user_id)
select nickname,user_id from public.kp_profiles
on conflict(nickname) do nothing;
do $check$
begin
  if exists(select 1 from public.kp_profiles p
    join public.kp_identity_reservations_v35 r on r.nickname=p.nickname
    where r.user_id is distinct from p.user_id) then
    raise exception 'Existing identity does not match its reservation';
  end if;
end $check$;

-- Include historical identities still visible in profiles, conversation keys,
-- DM indexes and the deletion audit. Never overwrite an active reservation.
insert into public.kp_identity_reservations_v35(nickname)
select distinct n from (
  select k.key as n from public.kp_tree_roots r
    cross join lateral jsonb_object_keys(coalesce(r.document,'{}'::jsonb)) k(key)
    where r.branch in ('users','dmIndex')
  union all
  select split_part(k.key,'__dm__',1) from public.kp_tree_roots r
    cross join lateral jsonb_object_keys(coalesce(r.document,'{}'::jsonb)) k(key)
    where r.branch='dms'
  union all
  select split_part(k.key,'__dm__',2) from public.kp_tree_roots r
    cross join lateral jsonb_object_keys(coalesce(r.document,'{}'::jsonb)) k(key)
    where r.branch='dms'
  union all
  select nickname from public.kp_deleted_account_audit
) historical
where n is not null and n<>''
on conflict(nickname) do nothing;

create or replace function public.kp_guard_identity_v35()
returns trigger language plpgsql security definer set search_path='' as $$
declare bound uuid;
begin
  if tg_op='UPDATE' then
    if new.nickname is distinct from old.nickname or new.user_id is distinct from old.user_id then
      raise exception 'Account identity is immutable';
    end if;
    return new;
  end if;
  if new.nickname is null or new.user_id is null or strpos(new.nickname,'__dm__')>0 then
    raise exception 'Invalid account identity';
  end if;
  insert into public.kp_identity_reservations_v35(nickname,user_id)
    values(new.nickname,new.user_id) on conflict(nickname) do nothing;
  select user_id into bound from public.kp_identity_reservations_v35 where nickname=new.nickname;
  if bound is distinct from new.user_id then
    raise exception 'Nickname is reserved';
  end if;
  return new;
end;
$$;
revoke all on function public.kp_guard_identity_v35() from public,anon,authenticated;
drop trigger if exists kp_guard_identity_v35 on public.kp_profiles;
create trigger kp_guard_identity_v35 before insert or update of nickname,user_id
on public.kp_profiles for each row execute function public.kp_guard_identity_v35();

create or replace function public.kp_nickname_reserved_v35(p_nick text)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.kp_identity_reservations_v35 where nickname=p_nick);
$$;
revoke all on function public.kp_nickname_reserved_v35(text) from public,anon,authenticated;
grant execute on function public.kp_nickname_reserved_v35(text) to service_role;

-- Serialize quota checks and inserts for one IP hash in a single transaction.
-- The gateway must still supply a trusted client IP; this is not a bot filter.
create or replace function public.kp_consume_signup_attempt_v35(p_ip_hash text)
returns boolean language plpgsql security definer set search_path='' as $$
declare cutoff timestamptz;
begin
  if p_ip_hash is null or p_ip_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Invalid signup quota key';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_ip_hash,35));
  cutoff:=clock_timestamp()-interval '1 hour';
  if (select count(*) from public.kp_signup_attempts
      where ip_hash=p_ip_hash and attempted_at>=cutoff)>=5 then
    return false;
  end if;
  insert into public.kp_signup_attempts(ip_hash,attempted_at)
    values(p_ip_hash,clock_timestamp());
  return true;
end;
$$;
revoke all on function public.kp_consume_signup_attempt_v35(text) from public,anon,authenticated;
grant execute on function public.kp_consume_signup_attempt_v35(text) to service_role;

-- Do not break existing public media URLs. Restrict listing/metadata access
-- even if another permissive Storage SELECT policy exists.
-- Public URL downloads are STILL public: a private bucket migration is needed.
drop policy if exists kp_media_read on storage.objects;
create policy kp_media_read on storage.objects for select to authenticated
  using (bucket_id='kapani-media' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists kp_media_no_cross_user_listing_v35 on storage.objects;
create policy kp_media_no_cross_user_listing_v35 on storage.objects as restrictive
  for select to anon,authenticated
  using (bucket_id<>'kapani-media' or (storage.foldername(name))[1]=(select auth.uid())::text);

commit;
