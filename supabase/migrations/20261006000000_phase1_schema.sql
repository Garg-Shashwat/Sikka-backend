-- Sikka Phase 1 schema.
--
-- Conventions
-- * Money is stored as bigint minor units (paise for INR) so splits never drift.
-- * IDs are uuids generated on the client, which makes offline creation and sync retries idempotent.
-- * updated_at is always set by the server (trigger) and is the cursor for incremental pulls.
-- * Rows are never hard-deleted by the app: deleted_at is a tombstone that syncs to other devices
--   and keeps historical references (e.g. an archived Person on old transactions) intact.

-- ---------------------------------------------------------------------------
-- Types & helpers
-- ---------------------------------------------------------------------------

create type public.transaction_type as enum ('expense', 'income', 'transfer', 'settlement', 'refund');

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Users (profile for an authenticated Sikka account)
-- ---------------------------------------------------------------------------

create table public.users (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null default '',
  email text,
  phone text,
  avatar_url text,
  default_currency char(3) not null default 'INR' check (default_currency ~ '^[A-Z]{3}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------

create table public.people (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null default auth.uid() references public.users (id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  phone text,
  avatar_url text,
  -- The owner's own Person record ("Me"). Exactly one per owner.
  is_self boolean not null default false,
  -- Reserved for a future phase: the Sikka account this Person represents. Not used in Phase 1.
  linked_user_id uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create unique index people_one_self_per_owner on public.people (owner_user_id) where is_self;
create index people_owner_updated on public.people (owner_user_id, updated_at);

-- ---------------------------------------------------------------------------
-- Groups (saved selections of People; not financial entities)
-- ---------------------------------------------------------------------------

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null default auth.uid() references public.users (id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  emoji text,
  color text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index groups_owner_updated on public.groups (owner_user_id, updated_at);

create table public.group_members (
  group_id uuid not null references public.groups (id) on delete cascade,
  person_id uuid not null references public.people (id) on delete restrict,
  primary key (group_id, person_id)
);

create index group_members_person on public.group_members (person_id);

-- ---------------------------------------------------------------------------
-- Categories / subcategories
-- ---------------------------------------------------------------------------

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null default auth.uid() references public.users (id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  icon text,
  color text,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index categories_owner_updated on public.categories (owner_user_id, updated_at);

create table public.subcategories (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null default auth.uid() references public.users (id) on delete cascade,
  category_id uuid not null references public.categories (id) on delete restrict,
  -- NULL name + is_category_default = the category itself ("Food" rather than "Food → Restaurant").
  name text,
  is_category_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint subcategories_default_has_no_name check (
    (is_category_default and name is null)
    or (not is_category_default and name is not null and length(btrim(name)) > 0)
  )
);

create unique index subcategories_one_default_per_category
  on public.subcategories (category_id) where is_category_default;
create index subcategories_owner_updated on public.subcategories (owner_user_id, updated_at);

-- ---------------------------------------------------------------------------
-- Tags
-- ---------------------------------------------------------------------------

create table public.tags (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null default auth.uid() references public.users (id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  color text,
  emoji text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index tags_owner_updated on public.tags (owner_user_id, updated_at);

-- ---------------------------------------------------------------------------
-- Transactions
-- ---------------------------------------------------------------------------
--
-- Every type uses payers + shares, and both must total the transaction amount:
--   expense     payers = who paid,              shares = who the expense is for
--   income      payers = shares = who received it (no effect on balances)
--   settlement  payers = who paid (from),       shares = who received (to)
--   transfer    payers = who sent money (from), shares = who received (to)
--   refund      payers = who received the refund money,
--               shares = whose cost the refund reduces (inverse of an expense)

create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null default auth.uid() references public.users (id) on delete cascade,
  type public.transaction_type not null,
  amount bigint not null check (amount > 0),
  currency char(3) not null default 'INR' check (currency ~ '^[A-Z]{3}$'),
  subcategory_id uuid references public.subcategories (id) on delete restrict,
  description text not null default '',
  date date not null default current_date,
  notes text,
  refund_of_id uuid references public.transactions (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint transactions_refund_of_only_for_refunds check (refund_of_id is null or type = 'refund'),
  constraint transactions_refund_not_self check (refund_of_id is null or refund_of_id <> id)
);

create index transactions_owner_updated on public.transactions (owner_user_id, updated_at);
create index transactions_owner_date on public.transactions (owner_user_id, date desc);

create table public.transaction_payers (
  transaction_id uuid not null references public.transactions (id) on delete cascade,
  person_id uuid not null references public.people (id) on delete restrict,
  amount bigint not null check (amount >= 0),
  primary key (transaction_id, person_id)
);

create table public.transaction_shares (
  transaction_id uuid not null references public.transactions (id) on delete cascade,
  person_id uuid not null references public.people (id) on delete restrict,
  amount bigint not null check (amount >= 0),
  primary key (transaction_id, person_id)
);

create index transaction_payers_person on public.transaction_payers (person_id);
create index transaction_shares_person on public.transaction_shares (person_id);

create table public.transaction_tags (
  transaction_id uuid not null references public.transactions (id) on delete cascade,
  tag_id uuid not null references public.tags (id) on delete restrict,
  primary key (transaction_id, tag_id)
);

create index transaction_tags_tag on public.transaction_tags (tag_id);

-- ---------------------------------------------------------------------------
-- Receipt attachments (files live in the private "receipts" storage bucket)
-- ---------------------------------------------------------------------------

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null default auth.uid() references public.users (id) on delete cascade,
  transaction_id uuid not null references public.transactions (id) on delete cascade,
  storage_path text not null unique,
  mime_type text,
  size_bytes bigint,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index attachments_owner_updated on public.attachments (owner_user_id, updated_at);
create index attachments_transaction on public.attachments (transaction_id);

-- ---------------------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------------------

create trigger users_updated_at before insert or update on public.users
  for each row execute function public.set_updated_at();
create trigger people_updated_at before insert or update on public.people
  for each row execute function public.set_updated_at();
create trigger groups_updated_at before insert or update on public.groups
  for each row execute function public.set_updated_at();
create trigger categories_updated_at before insert or update on public.categories
  for each row execute function public.set_updated_at();
create trigger subcategories_updated_at before insert or update on public.subcategories
  for each row execute function public.set_updated_at();
create trigger tags_updated_at before insert or update on public.tags
  for each row execute function public.set_updated_at();
create trigger transactions_updated_at before insert or update on public.transactions
  for each row execute function public.set_updated_at();
create trigger attachments_updated_at before insert or update on public.attachments
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Integrity: payer and share totals must equal the transaction amount.
-- Checked at commit (deferred) so a transaction and its rows can be written in any order.
-- ---------------------------------------------------------------------------

create or replace function public.check_transaction_totals()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
  v_amount bigint;
  v_paid bigint;
  v_shared bigint;
begin
  if tg_table_name = 'transactions' then
    v_id := new.id;
  elsif tg_op = 'DELETE' then
    v_id := old.transaction_id;
  else
    v_id := new.transaction_id;
  end if;

  select amount into v_amount from public.transactions where id = v_id;
  if not found then
    return null; -- parent deleted (cascade)
  end if;

  select coalesce(sum(amount), 0) into v_paid from public.transaction_payers where transaction_id = v_id;
  select coalesce(sum(amount), 0) into v_shared from public.transaction_shares where transaction_id = v_id;

  if v_paid <> v_amount then
    raise exception 'Payer total (%) must equal transaction amount (%) for %', v_paid, v_amount, v_id
      using errcode = 'check_violation';
  end if;
  if v_shared <> v_amount then
    raise exception 'Share total (%) must equal transaction amount (%) for %', v_shared, v_amount, v_id
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

create constraint trigger transactions_totals
  after insert or update on public.transactions
  deferrable initially deferred
  for each row execute function public.check_transaction_totals();
create constraint trigger transaction_payers_totals
  after insert or update or delete on public.transaction_payers
  deferrable initially deferred
  for each row execute function public.check_transaction_totals();
create constraint trigger transaction_shares_totals
  after insert or update or delete on public.transaction_shares
  deferrable initially deferred
  for each row execute function public.check_transaction_totals();

-- ---------------------------------------------------------------------------
-- Row Level Security: every row belongs to exactly one owner in Phase 1.
-- Ownership lives in owner_user_id (rather than being implied), so future sharing can be
-- added by widening these policies without reshaping the data.
-- ---------------------------------------------------------------------------

alter table public.users enable row level security;
alter table public.people enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.categories enable row level security;
alter table public.subcategories enable row level security;
alter table public.tags enable row level security;
alter table public.transactions enable row level security;
alter table public.transaction_payers enable row level security;
alter table public.transaction_shares enable row level security;
alter table public.transaction_tags enable row level security;
alter table public.attachments enable row level security;

create or replace function public.owns_person(p_person_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (
    select 1 from public.people where id = p_person_id and owner_user_id = (select auth.uid())
  );
$$;

-- SECURITY DEFINER so policies on transactions can reference other transactions
-- (refund_of_id) without recursing into their own RLS. It only ever answers for auth.uid().
create or replace function public.owns_transaction(p_transaction_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.transactions where id = p_transaction_id and owner_user_id = (select auth.uid())
  );
$$;

-- users
create policy users_select on public.users for select to authenticated
  using (id = (select auth.uid()));
create policy users_update on public.users for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Owned tables: select/insert/update own rows. No delete policy: the app soft-deletes.
create policy people_select on public.people for select to authenticated
  using (owner_user_id = (select auth.uid()));
create policy people_insert on public.people for insert to authenticated
  with check (owner_user_id = (select auth.uid()));
create policy people_update on public.people for update to authenticated
  using (owner_user_id = (select auth.uid())) with check (owner_user_id = (select auth.uid()));

create policy groups_select on public.groups for select to authenticated
  using (owner_user_id = (select auth.uid()));
create policy groups_insert on public.groups for insert to authenticated
  with check (owner_user_id = (select auth.uid()));
create policy groups_update on public.groups for update to authenticated
  using (owner_user_id = (select auth.uid())) with check (owner_user_id = (select auth.uid()));

create policy categories_select on public.categories for select to authenticated
  using (owner_user_id = (select auth.uid()));
create policy categories_insert on public.categories for insert to authenticated
  with check (owner_user_id = (select auth.uid()));
create policy categories_update on public.categories for update to authenticated
  using (owner_user_id = (select auth.uid())) with check (owner_user_id = (select auth.uid()));

create policy subcategories_select on public.subcategories for select to authenticated
  using (owner_user_id = (select auth.uid()));
create policy subcategories_insert on public.subcategories for insert to authenticated
  with check (
    owner_user_id = (select auth.uid())
    and exists (select 1 from public.categories c
                where c.id = category_id and c.owner_user_id = (select auth.uid()))
  );
create policy subcategories_update on public.subcategories for update to authenticated
  using (owner_user_id = (select auth.uid()))
  with check (
    owner_user_id = (select auth.uid())
    and exists (select 1 from public.categories c
                where c.id = category_id and c.owner_user_id = (select auth.uid()))
  );

create policy tags_select on public.tags for select to authenticated
  using (owner_user_id = (select auth.uid()));
create policy tags_insert on public.tags for insert to authenticated
  with check (owner_user_id = (select auth.uid()));
create policy tags_update on public.tags for update to authenticated
  using (owner_user_id = (select auth.uid())) with check (owner_user_id = (select auth.uid()));

create policy transactions_select on public.transactions for select to authenticated
  using (owner_user_id = (select auth.uid()));
create policy transactions_insert on public.transactions for insert to authenticated
  with check (
    owner_user_id = (select auth.uid())
    and (subcategory_id is null or exists (
      select 1 from public.subcategories s
      where s.id = subcategory_id and s.owner_user_id = (select auth.uid())))
    and (refund_of_id is null or public.owns_transaction(refund_of_id))
  );
create policy transactions_update on public.transactions for update to authenticated
  using (owner_user_id = (select auth.uid()))
  with check (
    owner_user_id = (select auth.uid())
    and (subcategory_id is null or exists (
      select 1 from public.subcategories s
      where s.id = subcategory_id and s.owner_user_id = (select auth.uid())))
    and (refund_of_id is null or public.owns_transaction(refund_of_id))
  );

create policy attachments_select on public.attachments for select to authenticated
  using (owner_user_id = (select auth.uid()));
create policy attachments_insert on public.attachments for insert to authenticated
  with check (owner_user_id = (select auth.uid()) and public.owns_transaction(transaction_id)
              and split_part(storage_path, '/', 1) = (select auth.uid())::text);
create policy attachments_update on public.attachments for update to authenticated
  using (owner_user_id = (select auth.uid()))
  with check (owner_user_id = (select auth.uid()) and public.owns_transaction(transaction_id)
              and split_part(storage_path, '/', 1) = (select auth.uid())::text);

-- Child tables: access follows the parent; referenced people/tags must also be the caller's.
create policy group_members_select on public.group_members for select to authenticated
  using (exists (select 1 from public.groups g where g.id = group_id and g.owner_user_id = (select auth.uid())));
create policy group_members_insert on public.group_members for insert to authenticated
  with check (
    exists (select 1 from public.groups g where g.id = group_id and g.owner_user_id = (select auth.uid()))
    and public.owns_person(person_id)
  );
create policy group_members_delete on public.group_members for delete to authenticated
  using (exists (select 1 from public.groups g where g.id = group_id and g.owner_user_id = (select auth.uid())));

create policy transaction_payers_select on public.transaction_payers for select to authenticated
  using (public.owns_transaction(transaction_id));
create policy transaction_payers_insert on public.transaction_payers for insert to authenticated
  with check (public.owns_transaction(transaction_id) and public.owns_person(person_id));
create policy transaction_payers_delete on public.transaction_payers for delete to authenticated
  using (public.owns_transaction(transaction_id));

create policy transaction_shares_select on public.transaction_shares for select to authenticated
  using (public.owns_transaction(transaction_id));
create policy transaction_shares_insert on public.transaction_shares for insert to authenticated
  with check (public.owns_transaction(transaction_id) and public.owns_person(person_id));
create policy transaction_shares_delete on public.transaction_shares for delete to authenticated
  using (public.owns_transaction(transaction_id));

create policy transaction_tags_select on public.transaction_tags for select to authenticated
  using (public.owns_transaction(transaction_id));
create policy transaction_tags_insert on public.transaction_tags for insert to authenticated
  with check (
    public.owns_transaction(transaction_id)
    and exists (select 1 from public.tags t where t.id = tag_id and t.owner_user_id = (select auth.uid()))
  );
create policy transaction_tags_delete on public.transaction_tags for delete to authenticated
  using (public.owns_transaction(transaction_id));

-- ---------------------------------------------------------------------------
-- Sync RPCs: write a whole aggregate atomically and idempotently.
-- SECURITY INVOKER, so every statement is still subject to the RLS policies above.
-- ---------------------------------------------------------------------------

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
    refund_of_id, created_at, deleted_at
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

create or replace function public.upsert_group(p jsonb)
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

  insert into public.groups as g (id, owner_user_id, name, emoji, color, created_at, deleted_at)
  values (
    v_id, v_uid, p ->> 'name', p ->> 'emoji', p ->> 'color',
    coalesce((p ->> 'created_at')::timestamptz, now()),
    (p ->> 'deleted_at')::timestamptz
  )
  on conflict (id) do update set
    name = excluded.name,
    emoji = excluded.emoji,
    color = excluded.color,
    deleted_at = excluded.deleted_at
  where g.owner_user_id = v_uid;

  if not found then
    raise exception 'Group % belongs to another user', v_id using errcode = '42501';
  end if;

  delete from public.group_members where group_id = v_id;
  insert into public.group_members (group_id, person_id)
    select distinct v_id, x.person_id::uuid
    from jsonb_array_elements_text(coalesce(p -> 'member_ids', '[]'::jsonb)) as x(person_id);
end;
$$;

revoke execute on function public.owns_transaction(uuid) from public, anon;
grant execute on function public.owns_transaction(uuid) to authenticated;
revoke execute on function public.upsert_transaction(jsonb) from public, anon;
revoke execute on function public.upsert_group(jsonb) from public, anon;
grant execute on function public.upsert_transaction(jsonb) to authenticated;
grant execute on function public.upsert_group(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- New account bootstrap: profile, the "Me" person, and starter categories.
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_category_id uuid;
  v_cat record;
  v_sub text;
  v_order integer := 0;
begin
  insert into public.users (id, name, email, phone)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'name', ''), split_part(coalesce(new.email, ''), '@', 1)),
    new.email,
    new.phone
  );

  insert into public.people (owner_user_id, name, is_self)
  values (new.id, 'Me', true);

  for v_cat in
    select * from (values
      ('Food', 'fork.knife', '#F97316', array['Groceries', 'Restaurant', 'Delivery', 'Snacks']),
      ('Transport', 'car', '#3B82F6', array['Fuel', 'Taxi', 'Public Transport', 'Parking']),
      ('Shopping', 'bag', '#EC4899', array['Clothing', 'Electronics', 'Household']),
      ('Home', 'house', '#8B5CF6', array['Rent', 'Electricity', 'Internet', 'Mobile', 'Repairs']),
      ('Health', 'cross.case', '#EF4444', array['Medicine', 'Doctor', 'Fitness']),
      ('Entertainment', 'film', '#14B8A6', array['Movies', 'Subscriptions', 'Outings']),
      ('Travel', 'airplane', '#0EA5E9', array['Hotel', 'Flights', 'Train', 'Sightseeing']),
      ('Education', 'book', '#6366F1', array['Fees', 'Books', 'Courses']),
      ('Personal Care', 'sparkles', '#D946EF', array['Salon', 'Cosmetics']),
      ('Gifts', 'gift', '#F43F5E', array['Gifts', 'Donations']),
      ('Income', 'banknote', '#22C55E', array['Salary', 'Business', 'Interest', 'Gift Received']),
      ('Other', 'ellipsis.circle', '#64748B', array[]::text[])
    ) as c(name, icon, color, subs)
  loop
    insert into public.categories (owner_user_id, name, icon, color, sort_order)
    values (new.id, v_cat.name, v_cat.icon, v_cat.color, v_order)
    returning id into v_category_id;
    v_order := v_order + 1;

    insert into public.subcategories (owner_user_id, category_id, name, is_category_default)
    values (new.id, v_category_id, null, true);

    foreach v_sub in array v_cat.subs loop
      insert into public.subcategories (owner_user_id, category_id, name, is_category_default)
      values (new.id, v_category_id, v_sub, false);
    end loop;
  end loop;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Realtime: lets other signed-in devices know there is something new to pull.
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table
      public.people, public.groups, public.categories, public.subcategories,
      public.tags, public.transactions, public.attachments;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Receipt storage: private bucket, files live under "<user id>/...".
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 10485760, array['image/jpeg', 'image/png', 'image/heic', 'image/webp'])
on conflict (id) do nothing;

create policy receipts_select on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy receipts_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy receipts_update on storage.objects for update to authenticated
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy receipts_delete on storage.objects for delete to authenticated
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = (select auth.uid())::text);
