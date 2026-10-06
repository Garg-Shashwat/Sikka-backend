-- A refund always belongs to the expense it refunds (the app only creates refunds from an expense).

-- If an expense row is ever hard-deleted (e.g. deleting a whole account), its refunds go with it
-- instead of being left pointing at nothing.
alter table public.transactions
  drop constraint transactions_refund_of_id_fkey,
  add constraint transactions_refund_of_id_fkey
    foreign key (refund_of_id) references public.transactions (id) on delete cascade;

-- NOT VALID: enforced for new and updated rows only, so refunds recorded before this rule
-- (while testing) don't block the migration.
alter table public.transactions
  add constraint transactions_refund_has_original
    check (type <> 'refund' or refund_of_id is not null) not valid;
