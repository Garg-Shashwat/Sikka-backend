-- Which group a transaction was entered under (e.g. "Family"), for group dashboards and
-- group balances. The people involved are still copied into payers/shares, so editing a
-- group's members never rewrites history, and a group expense can leave some members out.

alter table public.transactions
  add column group_id uuid references public.groups (id) on delete set null;

create index transactions_group on public.transactions (group_id) where group_id is not null;

-- The group, like the category and the refunded expense, must belong to the same user.
drop policy transactions_insert on public.transactions;
drop policy transactions_update on public.transactions;

create policy transactions_insert on public.transactions for insert to authenticated
  with check (
    owner_user_id = (select auth.uid())
    and (subcategory_id is null or exists (
      select 1 from public.subcategories s
      where s.id = subcategory_id and s.owner_user_id = (select auth.uid())))
    and (refund_of_id is null or public.owns_transaction(refund_of_id))
    and (group_id is null or exists (
      select 1 from public.groups g
      where g.id = group_id and g.owner_user_id = (select auth.uid())))
  );

create policy transactions_update on public.transactions for update to authenticated
  using (owner_user_id = (select auth.uid()))
  with check (
    owner_user_id = (select auth.uid())
    and (subcategory_id is null or exists (
      select 1 from public.subcategories s
      where s.id = subcategory_id and s.owner_user_id = (select auth.uid())))
    and (refund_of_id is null or public.owns_transaction(refund_of_id))
    and (group_id is null or exists (
      select 1 from public.groups g
      where g.id = group_id and g.owner_user_id = (select auth.uid())))
  );

-- Same as before, plus group_id.
create or replace function public.upsert_transaction(p jsonb)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid := (p ->> 'id')::uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  insert into public.transactions as t (
    id, owner_user_id, type, amount, currency, subcategory_id, description, date, notes,
    refund_of_id, group_id, created_at, deleted_at
  ) values (
    v_id,
    v_uid,
    (p ->> 'type')::public.transaction_type,
    (p ->> 'amount')::bigint,
    coalesce(p ->> 'currency', 'INR'),
    (p ->> 'subcategory_id')::uuid,
    coalesce(p ->> 'description', ''),
    (p ->> 'date')::date,
    p ->> 'notes',
    (p ->> 'refund_of_id')::uuid,
    (p ->> 'group_id')::uuid,
    coalesce((p ->> 'created_at')::timestamptz, now()),
    (p ->> 'deleted_at')::timestamptz
  )
  on conflict (id) do update set
    type = excluded.type,
    amount = excluded.amount,
    currency = excluded.currency,
    subcategory_id = excluded.subcategory_id,
    description = excluded.description,
    date = excluded.date,
    notes = excluded.notes,
    refund_of_id = excluded.refund_of_id,
    group_id = excluded.group_id,
    deleted_at = excluded.deleted_at
  where t.owner_user_id = v_uid;

  if not found then
    raise exception 'Transaction % belongs to another user', v_id using errcode = '42501';
  end if;

  delete from public.transaction_payers where transaction_id = v_id;
  insert into public.transaction_payers (transaction_id, person_id, amount)
    select v_id, x.person_id, x.amount
    from jsonb_to_recordset(coalesce(p -> 'payers', '[]'::jsonb)) as x(person_id uuid, amount bigint);

  delete from public.transaction_shares where transaction_id = v_id;
  insert into public.transaction_shares (transaction_id, person_id, amount)
    select v_id, x.person_id, x.amount
    from jsonb_to_recordset(coalesce(p -> 'shares', '[]'::jsonb)) as x(person_id uuid, amount bigint);

  delete from public.transaction_tags where transaction_id = v_id;
  insert into public.transaction_tags (transaction_id, tag_id)
    select distinct v_id, x.tag_id::uuid
    from jsonb_array_elements_text(coalesce(p -> 'tag_ids', '[]'::jsonb)) as x(tag_id);
end;
$$;
