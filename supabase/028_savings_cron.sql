-- Revision 28. Apply after 024_savings_ledger_account.sql.
-- Scheduled, idempotent savings interest. The cron runner is the postgres role;
-- app users cannot invoke the private runner or change its run history.
begin;

create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

create schema if not exists kp_internal;
revoke all on schema kp_internal from public, anon, authenticated;

create table if not exists kp_internal.savings_job_runs (
  id bigint generated always as identity primary key,
  ran_at timestamptz not null default clock_timestamp(),
  scanned integer not null check (scanned >= 0),
  initialized integer not null check (initialized >= 0),
  credited_users integer not null check (credited_users >= 0),
  credited_total bigint not null check (credited_total >= 0)
);
revoke all on table kp_internal.savings_job_runs from public, anon, authenticated;

create or replace function kp_internal.accrue_all_savings()
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  doc jsonb;
  revision_before bigint;
  current_profile jsonb;
  outcome jsonb;
  p record;
  now_ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  days_due bigint;
  interest bigint;
  scanned_count integer := 0;
  initialized_count integer := 0;
  credited_count integer := 0;
  credited_sum bigint := 0;
  changed boolean := false;
begin
  -- This is a SQL-only cron task, never an authenticated user RPC.
  if current_user <> 'postgres' then
    raise exception 'Internal task may only be run by postgres';
  end if;

  select document, revision into doc, revision_before
  from public.kp_tree_roots where branch = 'users' for update;
  if not found then
    raise exception 'Users tree missing';
  end if;

  for p in select nickname, user_id from public.kp_profiles order by nickname loop
    current_profile := doc -> p.nickname;
    if current_profile is null or jsonb_typeof(current_profile) <> 'object' then
      continue;
    end if;
    scanned_count := scanned_count + 1;

    outcome := public.kp_savings_math_v14(current_profile, now_ms);
    days_due := (outcome ->> 'days')::bigint;
    interest := (outcome ->> 'credited')::bigint;

    if not (current_profile ? 'savingsAccrualV14At') or days_due > 0 then
      if not (current_profile ? 'savingsAccrualV14At') then
        initialized_count := initialized_count + 1;
      end if;
      doc := jsonb_set(doc, array[p.nickname], outcome -> 'profile', true);
      changed := true;
    end if;

    if interest > 0 then
      -- The users-tree lock serializes this with user-triggered accrual and
      -- savings moves. Any failure rolls back BOTH interest and ledger.
      insert into public.kp_ledger(operation_id, user_id, account, amount, kind, details)
      values (gen_random_uuid(), p.user_id, 'savings', interest, 'savings_interest',
        jsonb_build_object('days', days_due, 'dailyRate', 0.003, 'source', 'cron'));
      credited_count := credited_count + 1;
      credited_sum := credited_sum + interest;
    end if;
  end loop;

  if changed then
    update public.kp_tree_roots
      set document = doc, revision = revision_before + 1, updated_at = now()
      where branch = 'users';
    insert into public.kp_tree_revisions(branch, revision)
      values ('users', revision_before + 1)
      on conflict (branch) do update set revision = excluded.revision;
  end if;

  insert into kp_internal.savings_job_runs(scanned, initialized, credited_users, credited_total)
    values (scanned_count, initialized_count, credited_count, credited_sum);
  return jsonb_build_object('ok', true, 'scanned', scanned_count,
    'initialized', initialized_count, 'creditedUsers', credited_count,
    'creditedTotal', credited_sum);
end;
$$;

revoke all on function kp_internal.accrue_all_savings() from public, anon, authenticated;
grant usage on schema kp_internal to postgres;
grant execute on function kp_internal.accrue_all_savings() to postgres;

select cron.schedule(
  'kp-savings-accrual-10m',
  '*/10 * * * *',
  'select kp_internal.accrue_all_savings()'
);

commit;
