-- Apply after 018 (and any later migrations already installed).
-- Savings interest is recorded in kp_ledger with account='savings'.
-- Preserve the existing account check and add that one account type.
begin;

do $$
declare
  rule text;
  expression text;
begin
  select pg_get_constraintdef(c.oid) into rule
  from pg_constraint c
  where c.conrelid='public.kp_ledger'::regclass
    and c.conname='kp_ledger_account_check'
    and c.contype='c';

  if rule is null then
    raise exception 'kp_ledger_account_check not found; inspect the ledger schema before applying 024';
  end if;
  if rule ~ '''savings''' then return; end if;
  expression := (regexp_match(rule, '^CHECK \((.*)\)$'))[1];
  if expression is null or expression !~ '\maccount\M' then
    raise exception 'Unexpected kp_ledger_account_check: %', rule;
  end if;

  alter table public.kp_ledger drop constraint kp_ledger_account_check;
  execute format(
    'alter table public.kp_ledger add constraint kp_ledger_account_check check ((%s) or account = %L)',
    expression, 'savings'
  );
end;
$$;

commit;
