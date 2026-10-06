-- Sharing between Sikka accounts (a shared ledger, like Splitwise).
--
-- Model
-- * A person can stand for a real account: people.linked_user_id. Everyone's own "Me" person is
--   linked to themselves. Links between two accounts are made only with consent (public.links):
--   by email request + accept, or by an invite code.
-- * Payer/share/group-member rows also record the account they stand for (user_id, filled by
--   trigger from the person). That is how a transaction created by A shows up for B: B's app maps
--   "user B" to its own Me and "user A" to its person for A.
-- * You can see a transaction if you created it, are a payer or share in it, or it belongs to a
--   group you are in. Anyone who can see it can edit it (family trust model).
-- * Still private per account: categories, tags (each person tags shared expenses their own way),
--   and people/groups that nothing shared refers to. Categories and people that a shared
--   transaction refers to become readable (name/icon only) to the others involved.
-- * People standing for an account can only be added to new expenses or groups by someone
--   connected with that account (or inside a group it is already in). Every change to a
--   transaction is recorded in transaction_history.
-- * Either side can disconnect; requests are by verified email (never revealing whether an
--   account exists), invite codes expire, and both are rate limited.
-- * The profile copy of the email (public.users.email) can't be edited by users.
-- * When something becomes newly visible (a link is accepted, someone is added to a group),
--   the affected rows get a fresh updated_at so incremental pulls pick them up.
-- * Writes to transactions, payers/shares and group members happen only through the RPCs below
--   (SECURITY DEFINER with explicit checks), so there are no direct-write policies for them.

-- ---------------------------------------------------------------------------
-- Profiles: users may change their name and settings, not the email copy.
-- ---------------------------------------------------------------------------

revoke update on public.users from anon, authenticated;
grant update (name, phone, avatar_url, default_currency) on public.users to authenticated;

-- ---------------------------------------------------------------------------
-- People ↔ accounts
-- ---------------------------------------------------------------------------

update public.people set linked_user_id = owner_user_id where is_self and linked_user_id is distinct from owner_user_id;

create unique index people_one_per_linked_user on public.people (owner_user_id, linked_user_id) where linked_user_id is not null;
create index people_linked_user on public.people (linked_user_id) where linked_user_id is not null;

-- "Me" is always linked to its owner, and stays "Me". Any other link can only be set inside the
-- linking functions (SECURITY DEFINER, so they run as the function owner, not as the caller's
-- API role). Requests through the API run as anon/authenticated and are refused.
create or replace function public.guard_person_link()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.is_self is distinct from old.is_self then
    raise exception 'Me can''t be changed into someone else' using errcode = '42501';
  end if;
  if new.is_self then
    new.linked_user_id := new.owner_user_id;
  elsif current_user in ('anon', 'authenticated')
        and new.linked_user_id is distinct from (case when tg_op = 'UPDATE' then old.linked_user_id end) then
    raise exception 'Connect people to accounts from the app''s connect screen' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger people_guard_link before insert or update on public.people
  for each row execute function public.guard_person_link();

-- ---------------------------------------------------------------------------
-- Which account each payer / share / group member stands for
-- ---------------------------------------------------------------------------

alter table public.transaction_payers add column user_id uuid references public.users (id) on delete set null;
alter table public.transaction_shares add column user_id uuid references public.users (id) on delete set null;
alter table public.group_members add column user_id uuid references public.users (id) on delete set null;

create index transaction_payers_user on public.transaction_payers (user_id) where user_id is not null;
create index transaction_shares_user on public.transaction_shares (user_id) where user_id is not null;
create index group_members_user on public.group_members (user_id) where user_id is not null;
create index transactions_subcategory on public.transactions (subcategory_id) where subcategory_id is not null;

create or replace function public.fill_member_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.user_id := (select linked_user_id from public.people where id = new.person_id);
  return new;
end;
$$;

create trigger transaction_payers_user before insert or update on public.transaction_payers
  for each row execute function public.fill_member_user();
create trigger transaction_shares_user before insert or update on public.transaction_shares
  for each row execute function public.fill_member_user();
create trigger group_members_user before insert or update on public.group_members
  for each row execute function public.fill_member_user();

update public.transaction_payers x set user_id = p.linked_user_id from public.people p where p.id = x.person_id;
update public.transaction_shares x set user_id = p.linked_user_id from public.people p where p.id = x.person_id;
update public.group_members x set user_id = p.linked_user_id from public.people p where p.id = x.person_id;

-- Tags stay personal: on a shared transaction each account sees only its own tags.
alter table public.transaction_tags add column owner_user_id uuid references public.users (id) on delete cascade;
update public.transaction_tags tt set owner_user_id = t.owner_user_id from public.tags t where t.id = tt.tag_id;
alter table public.transaction_tags alter column owner_user_id set not null;
alter table public.transaction_tags alter column owner_user_id set default auth.uid();

-- ---------------------------------------------------------------------------
-- Visibility (SECURITY DEFINER so policies can use them without recursing; they only ever
-- answer for auth.uid()).
-- ---------------------------------------------------------------------------

create or replace function public.my_group_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.groups where owner_user_id = (select auth.uid())
  union
  -- Members stop seeing a group (and expenses they're not part of) once its creator deletes it.
  select m.group_id from public.group_members m join public.groups g on g.id = m.group_id
  where m.user_id = (select auth.uid()) and g.deleted_at is null
$$;

create or replace function public.visible_transaction_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.transactions where owner_user_id = (select auth.uid())
  union
  select transaction_id from public.transaction_payers where user_id = (select auth.uid())
  union
  select transaction_id from public.transaction_shares where user_id = (select auth.uid())
  union
  select id from public.transactions where group_id in (select public.my_group_ids())
$$;

create or replace function public.can_see_transaction(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
      select 1 from public.transactions t
      where t.id = p_id
        and (t.owner_user_id = (select auth.uid()) or t.group_id in (select public.my_group_ids())))
    or exists (select 1 from public.transaction_payers where transaction_id = p_id and user_id = (select auth.uid()))
    or exists (select 1 from public.transaction_shares where transaction_id = p_id and user_id = (select auth.uid()))
$$;

create or replace function public.visible_person_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.people where owner_user_id = (select auth.uid()) or linked_user_id = (select auth.uid())
  union
  select person_id from public.transaction_payers where transaction_id in (select public.visible_transaction_ids())
  union
  select person_id from public.transaction_shares where transaction_id in (select public.visible_transaction_ids())
  union
  select person_id from public.group_members where group_id in (select public.my_group_ids())
$$;

create or replace function public.visible_subcategory_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.subcategories where owner_user_id = (select auth.uid())
  union
  select subcategory_id from public.transactions
  where subcategory_id is not null and id in (select public.visible_transaction_ids())
$$;

create or replace function public.visible_category_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.categories where owner_user_id = (select auth.uid())
  union
  select category_id from public.subcategories where id in (select public.visible_subcategory_ids())
$$;

create or replace function public.can_read_receipt(p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.attachments a
    where a.storage_path = p_path and a.transaction_id in (select public.visible_transaction_ids())
  )
$$;

-- Give rows a fresh updated_at so other accounts' incremental pulls pick them up when they
-- become visible (and bring the people/categories they refer to along).
create or replace function public.touch_transactions(p_ids uuid[])
returns void
language sql
security definer
set search_path = ''
as $$
  update public.transactions set updated_at = now() where id = any(p_ids);
  update public.people set updated_at = now() where id in (
    select person_id from public.transaction_payers where transaction_id = any(p_ids)
    union select person_id from public.transaction_shares where transaction_id = any(p_ids));
  update public.subcategories set updated_at = now() where id in (
    select subcategory_id from public.transactions where id = any(p_ids));
  update public.categories set updated_at = now() where id in (
    select s.category_id from public.subcategories s
    join public.transactions t on t.subcategory_id = s.id where t.id = any(p_ids));
  update public.attachments set updated_at = now() where transaction_id = any(p_ids);
$$;

create or replace function public.touch_groups(p_ids uuid[])
returns void
language sql
security definer
set search_path = ''
as $$
  update public.groups set updated_at = now() where id = any(p_ids);
  update public.people set updated_at = now() where id in (
    select person_id from public.group_members where group_id = any(p_ids));
  select public.touch_transactions(array(select id from public.transactions where group_id = any(p_ids)));
$$;

-- ---------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------

drop policy people_select on public.people;
create policy people_select on public.people for select to authenticated
  using (id in (select public.visible_person_ids()));

drop policy groups_select on public.groups;
create policy groups_select on public.groups for select to authenticated
  using (id in (select public.my_group_ids()));
drop policy groups_insert on public.groups;
drop policy groups_update on public.groups;

drop policy group_members_select on public.group_members;
drop policy group_members_insert on public.group_members;
drop policy group_members_delete on public.group_members;
create policy group_members_select on public.group_members for select to authenticated
  using (group_id in (select public.my_group_ids()));

drop policy categories_select on public.categories;
create policy categories_select on public.categories for select to authenticated
  using (id in (select public.visible_category_ids()));

drop policy subcategories_select on public.subcategories;
create policy subcategories_select on public.subcategories for select to authenticated
  using (id in (select public.visible_subcategory_ids()));

drop policy transactions_select on public.transactions;
drop policy transactions_insert on public.transactions;
drop policy transactions_update on public.transactions;
create policy transactions_select on public.transactions for select to authenticated
  using (id in (select public.visible_transaction_ids()));

drop policy transaction_payers_select on public.transaction_payers;
drop policy transaction_payers_insert on public.transaction_payers;
drop policy transaction_payers_delete on public.transaction_payers;
create policy transaction_payers_select on public.transaction_payers for select to authenticated
  using (transaction_id in (select public.visible_transaction_ids()));

drop policy transaction_shares_select on public.transaction_shares;
drop policy transaction_shares_insert on public.transaction_shares;
drop policy transaction_shares_delete on public.transaction_shares;
create policy transaction_shares_select on public.transaction_shares for select to authenticated
  using (transaction_id in (select public.visible_transaction_ids()));

drop policy transaction_tags_select on public.transaction_tags;
drop policy transaction_tags_insert on public.transaction_tags;
drop policy transaction_tags_delete on public.transaction_tags;
create policy transaction_tags_select on public.transaction_tags for select to authenticated
  using (owner_user_id = (select auth.uid()));

drop policy attachments_select on public.attachments;
drop policy attachments_insert on public.attachments;
drop policy attachments_update on public.attachments;
create policy attachments_select on public.attachments for select to authenticated
  using (transaction_id in (select public.visible_transaction_ids()));
create policy attachments_insert on public.attachments for insert to authenticated
  with check (owner_user_id = (select auth.uid()) and public.can_see_transaction(transaction_id)
              and split_part(storage_path, '/', 1) = (select auth.uid())::text);
create policy attachments_update on public.attachments for update to authenticated
  using (owner_user_id = (select auth.uid()))
  with check (owner_user_id = (select auth.uid()) and public.can_see_transaction(transaction_id)
              and split_part(storage_path, '/', 1) = (select auth.uid())::text);

-- Receipts on a shared transaction can be viewed by everyone who sees the transaction.
drop policy receipts_select on storage.objects;
create policy receipts_select on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and (
    (storage.foldername(name))[1] = (select auth.uid())::text or public.can_read_receipt(name)));

-- ---------------------------------------------------------------------------
-- Writes
-- ---------------------------------------------------------------------------

-- Accounts I'm connected with (including myself): people I own that stand for an account.
create or replace function public.connected_user_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select linked_user_id from public.people
  where owner_user_id = (select auth.uid()) and linked_user_id is not null
$$;

-- People standing for an account may only be added by someone connected with that account,
-- or inside a group that account is already in. Stops a connected user dragging a third
-- account (one they only know through someone else's records) into new expenses or groups.
-- Returns the first person that isn't allowed, or null.
create or replace function public.unconsented_person(p_people uuid[], p_keep uuid[], p_group uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.id from public.people p
  where p.id = any(p_people)
    and p.linked_user_id is not null
    and p.linked_user_id not in (select public.connected_user_ids())
    and not (p.id = any(coalesce(p_keep, '{}')))
    and not (p_group is not null and exists (
      select 1 from public.group_members m where m.group_id = p_group and m.user_id = p.linked_user_id))
  limit 1
$$;

-- Edit history of shared ledgers: who changed what, so edits by others are never silent.
create table public.transaction_history (
  id bigint generated always as identity primary key,
  transaction_id uuid not null references public.transactions (id) on delete cascade,
  changed_by uuid references public.users (id) on delete set null,
  changed_at timestamptz not null default now(),
  action text not null check (action in ('created', 'edited', 'deleted', 'restored')),
  -- Amount, date, description, type, payers and shares before/after (notes are left out).
  before jsonb,
  after jsonb
);

create index transaction_history_tx on public.transaction_history (transaction_id, changed_at);

alter table public.transaction_history enable row level security;
create policy transaction_history_select on public.transaction_history for select to authenticated
  using (public.can_see_transaction(transaction_id));

create or replace function public.transaction_snapshot(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'type', t.type, 'amount', t.amount, 'description', t.description, 'date', t.date,
    'group_id', t.group_id, 'subcategory_id', t.subcategory_id, 'deleted', t.deleted_at is not null,
    'payers', coalesce((select jsonb_agg(jsonb_build_object('person_id', x.person_id, 'user_id', x.user_id, 'amount', x.amount) order by x.person_id)
                        from public.transaction_payers x where x.transaction_id = t.id), '[]'),
    'shares', coalesce((select jsonb_agg(jsonb_build_object('person_id', x.person_id, 'user_id', x.user_id, 'amount', x.amount) order by x.person_id)
                        from public.transaction_shares x where x.transaction_id = t.id), '[]'))
  from public.transactions t where t.id = p_id
$$;

create or replace function public.upsert_transaction(p jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid := (p ->> 'id')::uuid;
  v_sub uuid := (p ->> 'subcategory_id')::uuid;
  v_group uuid := (p ->> 'group_id')::uuid;
  v_refund uuid := (p ->> 'refund_of_id')::uuid;
  v_exists boolean;
  v_bad text;
  v_people uuid[];
  v_prev uuid[];
  v_before jsonb;
  v_after jsonb;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  v_exists := exists (select 1 from public.transactions where id = v_id);
  if v_exists and not public.can_see_transaction(v_id) then
    raise exception 'Transaction % belongs to another user', v_id using errcode = '42501';
  end if;

  if v_sub is not null and v_sub not in (select public.visible_subcategory_ids()) then
    raise exception 'Category % is not available to you', v_sub using errcode = '42501';
  end if;
  if v_group is not null and v_group not in (select public.my_group_ids()) then
    raise exception 'Group % is not available to you', v_group using errcode = '42501';
  end if;
  if v_refund is not null and not public.can_see_transaction(v_refund) then
    raise exception 'Expense % is not available to you', v_refund using errcode = '42501';
  end if;

  v_people := array(
    select x.person_id
    from jsonb_to_recordset(coalesce(p -> 'payers', '[]'::jsonb) || coalesce(p -> 'shares', '[]'::jsonb)) as x(person_id uuid));

  select x into v_bad from unnest(v_people) as x where x not in (select public.visible_person_ids()) limit 1;
  if v_bad is not null then
    raise exception 'Person % is not available to you', v_bad using errcode = '42501';
  end if;

  -- People already on this transaction can stay; new ones must be connected to me (or in the group).
  v_prev := array(
    select person_id from public.transaction_payers where transaction_id = v_id
    union select person_id from public.transaction_shares where transaction_id = v_id);
  v_bad := public.unconsented_person(v_people, v_prev, v_group);
  if v_bad is not null then
    raise exception 'You can only add people you are connected with, or who are in this group'
      using errcode = '42501';
  end if;

  select x.tag_id into v_bad
  from jsonb_array_elements_text(coalesce(p -> 'tag_ids', '[]'::jsonb)) as x(tag_id)
  where not exists (select 1 from public.tags t where t.id = x.tag_id::uuid and t.owner_user_id = v_uid)
  limit 1;
  if v_bad is not null then
    raise exception 'Tag % is not yours', v_bad using errcode = '42501';
  end if;

  v_before := case when v_exists then public.transaction_snapshot(v_id) end;

  insert into public.transactions as t (
    id, owner_user_id, type, amount, currency, subcategory_id, description, date, notes,
    refund_of_id, group_id, created_at, deleted_at
  ) values (
    v_id,
    v_uid,
    (p ->> 'type')::public.transaction_type,
    (p ->> 'amount')::bigint,
    coalesce(p ->> 'currency', 'INR'),
    v_sub,
    coalesce(p ->> 'description', ''),
    (p ->> 'date')::date,
    p ->> 'notes',
    v_refund,
    v_group,
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
    deleted_at = excluded.deleted_at;

  delete from public.transaction_payers where transaction_id = v_id;
  insert into public.transaction_payers (transaction_id, person_id, amount)
    select v_id, x.person_id, x.amount
    from jsonb_to_recordset(coalesce(p -> 'payers', '[]'::jsonb)) as x(person_id uuid, amount bigint);

  delete from public.transaction_shares where transaction_id = v_id;
  insert into public.transaction_shares (transaction_id, person_id, amount)
    select v_id, x.person_id, x.amount
    from jsonb_to_recordset(coalesce(p -> 'shares', '[]'::jsonb)) as x(person_id uuid, amount bigint);

  -- Only the caller's own tags are replaced; others keep theirs.
  delete from public.transaction_tags where transaction_id = v_id and owner_user_id = v_uid;
  insert into public.transaction_tags (transaction_id, tag_id, owner_user_id)
    select distinct v_id, x.tag_id::uuid, v_uid
    from jsonb_array_elements_text(coalesce(p -> 'tag_ids', '[]'::jsonb)) as x(tag_id);

  v_after := public.transaction_snapshot(v_id);
  if v_before is distinct from v_after then
    insert into public.transaction_history (transaction_id, changed_by, action, before, after)
    values (
      v_id, v_uid,
      case
        when v_before is null then 'created'
        when (v_after ->> 'deleted')::boolean and not (v_before ->> 'deleted')::boolean then 'deleted'
        when (v_before ->> 'deleted')::boolean and not (v_after ->> 'deleted')::boolean then 'restored'
        else 'edited'
      end,
      v_before, v_after);
  end if;

  -- Shared with other accounts: make sure they can pull the people and category it mentions.
  if v_group is not null or exists (
    select 1 from public.transaction_payers where transaction_id = v_id and user_id is not null and user_id <> v_uid
    union all
    select 1 from public.transaction_shares where transaction_id = v_id and user_id is not null and user_id <> v_uid
  ) then
    perform public.touch_transactions(array[v_id]);
  end if;
end;
$$;

-- Groups are edited by their creator only. Members can be anyone visible to the creator; members
-- that stand for an account must be connected to the creator (or already in the group).
create or replace function public.upsert_group(p jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid := (p ->> 'id')::uuid;
  v_owner uuid;
  v_bad uuid;
  v_members uuid[];
  v_prev uuid[];
  v_before uuid[];
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select owner_user_id into v_owner from public.groups where id = v_id;
  if found and v_owner <> v_uid then
    raise exception 'Group % belongs to another user', v_id using errcode = '42501';
  end if;

  v_members := array(select distinct x::uuid from jsonb_array_elements_text(coalesce(p -> 'member_ids', '[]'::jsonb)) as x);
  select x into v_bad from unnest(v_members) as x where x not in (select public.visible_person_ids()) limit 1;
  if v_bad is not null then
    raise exception 'Person % is not available to you', v_bad using errcode = '42501';
  end if;
  v_prev := array(select person_id from public.group_members where group_id = v_id);
  if public.unconsented_person(v_members, v_prev, null) is not null then
    raise exception 'You can only add people you are connected with' using errcode = '42501';
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
    deleted_at = excluded.deleted_at;

  v_before := array(select user_id from public.group_members where group_id = v_id and user_id is not null);

  delete from public.group_members where group_id = v_id;
  insert into public.group_members (group_id, person_id) select v_id, x from unnest(v_members) as x;

  -- Someone newly in the group: they now see its history.
  if exists (
    select 1 from public.group_members
    where group_id = v_id and user_id is not null and user_id <> v_uid and not (user_id = any(v_before))
  ) then
    perform public.touch_groups(array[v_id]);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Connecting accounts
-- ---------------------------------------------------------------------------
--
-- A request is addressed to an email, not an account: it succeeds whether or not that email has
-- a Sikka account (so nobody can probe which emails are registered), and the person sees it once
-- they sign in with that verified email. Invite codes are one-time, short-lived bearer codes.
-- Both are limited per account per day; wrong invite codes are limited per hour.

-- My verified login email (never the editable profile copy).
create or replace function public.my_email()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select lower(email) from auth.users where id = (select auth.uid()) and email_confirmed_at is not null
$$;

create table public.links (
  id uuid primary key default gen_random_uuid(),
  -- Who asked, and their person for the other account.
  from_user uuid not null references public.users (id) on delete cascade,
  from_person uuid not null references public.people (id) on delete cascade,
  from_name text not null default '',
  from_email text,
  -- Who was asked: an email for requests (to_user is filled in on accepting), nothing for codes.
  to_user uuid references public.users (id) on delete cascade,
  to_email text,
  to_person uuid references public.people (id) on delete set null,
  invite_code text unique,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined', 'cancelled', 'disconnected')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index links_from_user on public.links (from_user, updated_at);
create index links_to_user on public.links (to_user, updated_at);
create index links_to_email on public.links (lower(to_email)) where status = 'pending';

create trigger links_updated_at before insert or update on public.links
  for each row execute function public.set_updated_at();

alter table public.links enable row level security;
create policy links_select on public.links for select to authenticated
  using (
    from_user = (select auth.uid())
    or to_user = (select auth.uid())
    or (to_user is null and invite_code is null and lower(to_email) = (select public.my_email()))
  );

-- Failed attempts that must be limited even though the call itself returns normally.
create table public.rate_events (
  user_id uuid not null references public.users (id) on delete cascade,
  kind text not null,
  at timestamptz not null default now()
);
create index rate_events_user_kind_at on public.rate_events (user_id, kind, at);
alter table public.rate_events enable row level security; -- no policies: only the functions below

-- Requests + invites: at most 20 per day and 30 waiting at once, per account.
create or replace function public.check_link_quota()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select count(*) from public.links where from_user = auth.uid() and created_at > now() - interval '1 day') >= 20 then
    raise exception 'You have sent a lot of requests today. Try again tomorrow.' using errcode = '54000';
  end if;
  if (select count(*) from public.links
      where from_user = auth.uid() and status = 'pending' and expires_at > now()) >= 30 then
    raise exception 'Too many requests are waiting. Cancel some first.' using errcode = '54000';
  end if;
end;
$$;

-- The caller's own, unlinked, active person (not "Me").
create or replace function public.linkable_person(p_person uuid)
returns public.people
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v public.people;
begin
  select * into v from public.people
  where id = p_person and owner_user_id = auth.uid() and not is_self and deleted_at is null;
  if not found then
    raise exception 'Person not found' using errcode = 'P0002';
  end if;
  if v.linked_user_id is not null then
    raise exception '% is already connected to an account', v.name using errcode = '23505';
  end if;
  return v;
end;
$$;

create or replace function public.request_link(p_person uuid, p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_mine text := public.my_email();
  v_id uuid;
begin
  perform public.linkable_person(p_person);
  if v_mine is null then
    raise exception 'Verify your email before connecting with others' using errcode = '42501';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then
    raise exception 'Enter a valid email' using errcode = '22023';
  end if;
  if v_email = v_mine then
    raise exception 'That is your own email' using errcode = '22023';
  end if;
  -- Only reveals something about accounts you are already connected with.
  if exists (
    select 1 from public.people p join auth.users u on u.id = p.linked_user_id
    where p.owner_user_id = v_uid and lower(u.email) = v_email
  ) then
    raise exception 'You are already connected with %', v_email using errcode = '23505';
  end if;
  if exists (
    select 1 from public.links
    where from_user = v_uid and lower(to_email) = v_email and status = 'declined' and updated_at > now() - interval '7 days'
  ) then
    raise exception '% declined recently. Try again in a few days.', v_email using errcode = '54000';
  end if;
  perform public.check_link_quota();

  update public.links set status = 'cancelled'
  where from_user = v_uid and status = 'pending' and (from_person = p_person or lower(to_email) = v_email);
  insert into public.links (from_user, from_person, from_name, from_email, to_email, expires_at)
  select v_uid, p_person, u.name, v_mine, v_email, now() + interval '30 days' from public.users u where u.id = v_uid
  returning id into v_id;
  return v_id;
end;
$$;

-- 10 characters from an alphabet without look-alikes (no 0/O, 1/I/L): 31^10 ≈ 8 × 10^14 codes.
-- Uses only the fully random bytes of a v4 uuid (bytes 6 and 8 carry version/variant bits).
create or replace function public.new_invite_code()
returns text
language sql
volatile
set search_path = ''
as $$
  select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', (get_byte(b, i) % 31) + 1, 1), '' order by i)
  from (select uuid_send(gen_random_uuid()) as b) r, unnest(array[0, 1, 2, 3, 4, 5, 9, 10, 11, 12]) as i
$$;

create or replace function public.create_invite(p_person uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
begin
  perform public.linkable_person(p_person);
  perform public.check_link_quota();
  update public.links set status = 'cancelled' where from_person = p_person and status = 'pending';
  loop
    v_code := public.new_invite_code();
    begin
      insert into public.links (from_user, from_person, from_name, from_email, invite_code, expires_at)
      select v_uid, p_person, u.name, public.my_email(), v_code, now() + interval '7 days'
      from public.users u where u.id = v_uid;
      return v_code;
    exception when unique_violation then
      -- try another code
    end;
  end loop;
end;
$$;

-- Accept a request (p_link) or an invite code (p_code). p_person: which of my people the other
-- account is; null creates a new person. Returns 'ok', or 'invalid_code' for a wrong/expired code
-- (returned rather than raised so the failed attempt is recorded for rate limiting).
create or replace function public.accept_link(p_link uuid default null, p_code text default null, p_person uuid default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_email text := public.my_email();
  v public.links;
  v_mine uuid;
  v_people uuid[];
  v_groups uuid[];
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  if p_link is not null then
    select * into v from public.links
    where id = p_link and status = 'pending' and expires_at > now() and invite_code is null
      and (to_user = v_uid or (to_user is null and lower(to_email) = v_email))
    for update;
    if not found then
      raise exception 'This request is no longer valid' using errcode = 'P0002';
    end if;
  else
    if (select count(*) from public.rate_events
        where user_id = v_uid and kind = 'bad_invite_code' and at > now() - interval '1 hour') >= 10 then
      raise exception 'Too many wrong codes. Try again in an hour.' using errcode = '54000';
    end if;
    select * into v from public.links
    where invite_code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'))
      and status = 'pending' and expires_at > now() and to_user is null
    for update;
    if not found then
      insert into public.rate_events (user_id, kind) values (v_uid, 'bad_invite_code');
      return 'invalid_code';
    end if;
  end if;

  if v.from_user = v_uid then
    raise exception 'That is your own invite' using errcode = '22023';
  end if;
  if exists (select 1 from public.people where owner_user_id = v_uid and linked_user_id = v.from_user)
     or exists (select 1 from public.people where owner_user_id = v.from_user and linked_user_id = v_uid) then
    raise exception 'You are already connected with %', v.from_name using errcode = '23505';
  end if;
  if (select linked_user_id from public.people where id = v.from_person) is not null then
    raise exception 'This request is no longer valid' using errcode = 'P0002';
  end if;

  if p_person is not null then
    perform public.linkable_person(p_person);
    v_mine := p_person;
    update public.people set linked_user_id = v.from_user where id = v_mine;
  else
    insert into public.people (owner_user_id, name, linked_user_id)
    values (v_uid, coalesce(nullif(btrim(v.from_name), ''), split_part(coalesce(v.from_email, 'Friend'), '@', 1)), v.from_user)
    returning id into v_mine;
  end if;
  update public.people set linked_user_id = v_uid where id = v.from_person;

  update public.links
  set status = 'accepted', to_user = v_uid, to_person = v_mine, to_email = coalesce(to_email, v_email)
  where id = v.id;

  -- Existing records about these two people now stand for the two accounts.
  v_people := array[v.from_person, v_mine];
  perform public.refresh_people_accounts(v_people);
  return 'ok';
end;
$$;

-- After a person's account changes: recompute user_id on their rows and make the affected
-- transactions and groups pull again for everyone who (still) sees them.
create or replace function public.refresh_people_accounts(p_people uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.transaction_payers set user_id = null where person_id = any(p_people); -- trigger refills
  update public.transaction_shares set user_id = null where person_id = any(p_people);
  update public.group_members set user_id = null where person_id = any(p_people);
  perform public.touch_transactions(array(
    select transaction_id from public.transaction_payers where person_id = any(p_people)
    union select transaction_id from public.transaction_shares where person_id = any(p_people)));
  perform public.touch_groups(array(select group_id from public.group_members where person_id = any(p_people)));
  update public.people set updated_at = now() where id = any(p_people);
end;
$$;

create or replace function public.decline_link(p_link uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.links set status = 'declined', to_user = auth.uid()
  where id = p_link and status = 'pending' and invite_code is null
    and (to_user = auth.uid() or (to_user is null and lower(to_email) = public.my_email()));
$$;

create or replace function public.cancel_link(p_link uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.links set status = 'cancelled' where id = p_link and from_user = auth.uid() and status = 'pending';
$$;

-- On records owned by p_owner, replace person p_from with p_to (amounts of duplicates are added).
create or replace function public.swap_person(p_owner uuid, p_from uuid, p_to uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_txs uuid[];
  v_groups uuid[];
begin
  if p_from is null or p_to is null or p_from = p_to then
    return;
  end if;
  v_txs := array(
    select t.id from public.transactions t
    where t.owner_user_id = p_owner and (
      exists (select 1 from public.transaction_payers x where x.transaction_id = t.id and x.person_id = p_from)
      or exists (select 1 from public.transaction_shares x where x.transaction_id = t.id and x.person_id = p_from)));
  v_groups := array(
    select g.id from public.groups g
    where g.owner_user_id = p_owner and exists (select 1 from public.group_members m where m.group_id = g.id and m.person_id = p_from));

  insert into public.transaction_payers as x (transaction_id, person_id, amount)
    select transaction_id, p_to, amount from public.transaction_payers where person_id = p_from and transaction_id = any(v_txs)
  on conflict (transaction_id, person_id) do update set amount = x.amount + excluded.amount;
  delete from public.transaction_payers where person_id = p_from and transaction_id = any(v_txs);
  insert into public.transaction_shares as x (transaction_id, person_id, amount)
    select transaction_id, p_to, amount from public.transaction_shares where person_id = p_from and transaction_id = any(v_txs)
  on conflict (transaction_id, person_id) do update set amount = x.amount + excluded.amount;
  delete from public.transaction_shares where person_id = p_from and transaction_id = any(v_txs);

  insert into public.group_members (group_id, person_id)
    select group_id, p_to from public.group_members where person_id = p_from and group_id = any(v_groups)
  on conflict do nothing;
  delete from public.group_members where person_id = p_from and group_id = any(v_groups);

  perform public.touch_transactions(v_txs);
  perform public.touch_groups(v_groups);
end;
$$;

-- Stop sharing with an account (either side can do it). Both sides keep their own records, with
-- the other person as a plain name; from now on neither sees the other's records.
create or replace function public.disconnect(p_person uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_other uuid;
  v_my_self uuid;
  v_their_self uuid;
  v_their_for_me uuid;
  v_people uuid[];
begin
  select linked_user_id into v_other from public.people
  where id = p_person and owner_user_id = v_uid and not is_self and linked_user_id is not null;
  if v_other is null then
    raise exception 'Not connected' using errcode = 'P0002';
  end if;
  select id into v_my_self from public.people where owner_user_id = v_uid and is_self;
  select id into v_their_self from public.people where owner_user_id = v_other and is_self;
  select id into v_their_for_me from public.people where owner_user_id = v_other and linked_user_id = v_uid;

  -- Each side's own "Me" on the other side's records becomes the plain person standing for them.
  perform public.swap_person(v_uid, v_their_self, p_person);
  perform public.swap_person(v_other, v_my_self, v_their_for_me);

  v_people := array_remove(array[p_person, v_their_for_me], null);
  update public.people set linked_user_id = null where id = any(v_people);
  update public.links set status = 'disconnected'
  where status = 'accepted'
    and ((from_user = v_uid and to_user = v_other) or (from_user = v_other and to_user = v_uid));
  perform public.refresh_people_accounts(v_people);
end;
$$;

-- Merge two of my people: everything recorded for p_from moves to p_into, then p_from is archived.
-- If only p_from is connected to an account, the connection moves to p_into.
create or replace function public.merge_people(p_from uuid, p_into uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  f public.people;
  i public.people;
  v_txs uuid[];
  v_groups uuid[];
begin
  select * into f from public.people where id = p_from and owner_user_id = v_uid and deleted_at is null;
  select * into i from public.people where id = p_into and owner_user_id = v_uid and deleted_at is null;
  if f.id is null or i.id is null or p_from = p_into then
    raise exception 'Choose two different people' using errcode = '22023';
  end if;
  if f.is_self then
    raise exception 'You can merge someone into Me, but not Me into someone' using errcode = '22023';
  end if;
  if f.linked_user_id is not null and i.linked_user_id is not null and f.linked_user_id <> i.linked_user_id then
    raise exception '% and % are connected to different accounts', f.name, i.name using errcode = '22023';
  end if;

  if f.linked_user_id is not null and i.linked_user_id is null then
    update public.people set linked_user_id = null where id = p_from;
    update public.people set linked_user_id = f.linked_user_id where id = p_into;
    update public.links set from_person = p_into where from_person = p_from;
    update public.links set to_person = p_into where to_person = p_from;
  end if;

  v_txs := array(
    select transaction_id from public.transaction_payers where person_id = p_from
    union select transaction_id from public.transaction_shares where person_id = p_from);
  v_groups := array(select group_id from public.group_members where person_id = p_from);

  insert into public.transaction_payers as x (transaction_id, person_id, amount)
    select transaction_id, p_into, amount from public.transaction_payers where person_id = p_from
  on conflict (transaction_id, person_id) do update set amount = x.amount + excluded.amount;
  delete from public.transaction_payers where person_id = p_from;

  insert into public.transaction_shares as x (transaction_id, person_id, amount)
    select transaction_id, p_into, amount from public.transaction_shares where person_id = p_from
  on conflict (transaction_id, person_id) do update set amount = x.amount + excluded.amount;
  delete from public.transaction_shares where person_id = p_from;

  insert into public.group_members (group_id, person_id)
    select group_id, p_into from public.group_members where person_id = p_from
  on conflict do nothing;
  delete from public.group_members where person_id = p_from;

  update public.people set deleted_at = now() where id = p_from;
  perform public.refresh_people_accounts(array[p_into]);
  perform public.touch_transactions(v_txs);
  perform public.touch_groups(v_groups);
end;
$$;

-- Ids of other accounts' rows this account can currently see. The app removes local copies of
-- shared rows that are no longer visible (e.g. after being removed from a group).
create or replace function public.visible_shared_ids()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'transactions', coalesce((select jsonb_agg(t.id) from public.transactions t
                              where t.id in (select public.visible_transaction_ids()) and t.owner_user_id <> auth.uid()), '[]'),
    'groups', coalesce((select jsonb_agg(g.id) from public.groups g
                        where g.id in (select public.my_group_ids()) and g.owner_user_id <> auth.uid()), '[]'),
    'people', coalesce((select jsonb_agg(p.id) from public.people p
                        where p.id in (select public.visible_person_ids()) and p.owner_user_id <> auth.uid()), '[]'),
    'categories', coalesce((select jsonb_agg(c.id) from public.categories c
                            where c.id in (select public.visible_category_ids()) and c.owner_user_id <> auth.uid()), '[]'),
    'subcategories', coalesce((select jsonb_agg(s.id) from public.subcategories s
                               where s.id in (select public.visible_subcategory_ids()) and s.owner_user_id <> auth.uid()), '[]'),
    'attachments', coalesce((select jsonb_agg(a.id) from public.attachments a
                             where a.transaction_id in (select public.visible_transaction_ids()) and a.owner_user_id <> auth.uid()), '[]')
  )
$$;

-- Display name of the account that owns a visible person (a shared "Me" is shown by this name).
create or replace function public.person_owner_name(p_person uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select u.name from public.people p join public.users u on u.id = p.owner_user_id
  where p.id = p_person and p.id in (select public.visible_person_ids())
$$;

-- ---------------------------------------------------------------------------
-- Pull: everything visible, not just owned rows (+ links, member user ids, own tags only).
-- ---------------------------------------------------------------------------

create or replace function public.pull_changes(p_since jsonb default '{}'::jsonb, p_limit int default 500)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  lim int := least(greatest(coalesce(p_limit, 500), 1), 1000);
  tables jsonb := '{}'::jsonb;
  more boolean := false;
  spec record;
  page jsonb;
  n int;
  since_ts timestamptz;
  since_id uuid;
begin
  if uid is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  p_since := coalesce(p_since, '{}'::jsonb);

  for spec in
    select * from (values
      ('users', 't.id = $1', 'to_jsonb(t)'),
      ('people', 't.id in (select public.visible_person_ids())',
        $e$to_jsonb(t) || jsonb_build_object('owner_name', case when t.owner_user_id <> $1 then public.person_owner_name(t.id) end)$e$),
      ('categories', 't.id in (select public.visible_category_ids())', 'to_jsonb(t)'),
      ('subcategories', 't.id in (select public.visible_subcategory_ids())', 'to_jsonb(t)'),
      ('tags', 't.owner_user_id = $1', 'to_jsonb(t)'),
      ('groups', 't.id in (select public.my_group_ids())',
        $e$to_jsonb(t) || jsonb_build_object('group_members', coalesce(
          (select jsonb_agg(jsonb_build_object('person_id', m.person_id, 'user_id', m.user_id))
           from public.group_members m where m.group_id = t.id), '[]'))$e$),
      ('transactions', 't.id in (select public.visible_transaction_ids())',
        $e$to_jsonb(t) || jsonb_build_object(
          'transaction_payers', coalesce(
            (select jsonb_agg(jsonb_build_object('person_id', x.person_id, 'amount', x.amount, 'user_id', x.user_id))
             from public.transaction_payers x where x.transaction_id = t.id), '[]'),
          'transaction_shares', coalesce(
            (select jsonb_agg(jsonb_build_object('person_id', x.person_id, 'amount', x.amount, 'user_id', x.user_id))
             from public.transaction_shares x where x.transaction_id = t.id), '[]'),
          'transaction_tags', coalesce(
            (select jsonb_agg(jsonb_build_object('tag_id', x.tag_id))
             from public.transaction_tags x where x.transaction_id = t.id and x.owner_user_id = $1), '[]'))$e$),
      ('attachments', 't.transaction_id in (select public.visible_transaction_ids())', 'to_jsonb(t)'),
      ('links', '(t.from_user = $1 or t.to_user = $1 or (t.to_user is null and t.invite_code is null and lower(t.to_email) = public.my_email()))',
        $e$to_jsonb(t) - case when t.from_user = $1 then '' else 'invite_code' end$e$)
    ) as s(tbl, visible, expr)
  loop
    since_ts := (p_since -> spec.tbl ->> 'ts')::timestamptz;
    since_id := coalesce((p_since -> spec.tbl ->> 'id')::uuid, '00000000-0000-0000-0000-000000000000'::uuid);

    execute format(
      'select coalesce(jsonb_agg(x.r order by x.updated_at, x.id), ''[]''::jsonb), count(*)::int from (
         select t.updated_at, t.id, %s as r
         from public.%I t
         where %s and ($2::timestamptz is null or (t.updated_at, t.id) > ($2, $3))
         order by t.updated_at, t.id
         limit $4
       ) x',
      spec.expr, spec.tbl, spec.visible)
    into page, n
    using uid, since_ts, since_id, lim;

    tables := tables || jsonb_build_object(spec.tbl, page);
    if n >= lim then
      more := true;
    end if;
  end loop;

  return jsonb_build_object('tables', tables, 'more', more);
end;
$$;

-- Realtime: requests, acceptances and disconnects reach the other account immediately.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.links;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Function privileges: helpers are internal; RPCs are for signed-in users.
-- ---------------------------------------------------------------------------

revoke execute on function public.touch_transactions(uuid[]) from public, anon, authenticated;
revoke execute on function public.refresh_people_accounts(uuid[]) from public, anon, authenticated;
revoke execute on function public.swap_person(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.connected_user_ids() from public, anon, authenticated;
revoke execute on function public.unconsented_person(uuid[], uuid[], uuid) from public, anon, authenticated;
revoke execute on function public.transaction_snapshot(uuid) from public, anon, authenticated;
revoke execute on function public.check_link_quota() from public, anon, authenticated;
revoke execute on function public.new_invite_code() from public, anon, authenticated;
revoke execute on function public.my_email() from public, anon;
grant execute on function public.my_email() to authenticated; -- used by the links policy
revoke execute on function public.touch_groups(uuid[]) from public, anon, authenticated;
revoke execute on function public.linkable_person(uuid) from public, anon, authenticated;
revoke execute on function public.fill_member_user() from public, anon, authenticated;

revoke execute on function public.my_group_ids() from public, anon;
revoke execute on function public.visible_transaction_ids() from public, anon;
revoke execute on function public.can_see_transaction(uuid) from public, anon;
revoke execute on function public.visible_person_ids() from public, anon;
revoke execute on function public.visible_subcategory_ids() from public, anon;
revoke execute on function public.visible_category_ids() from public, anon;
revoke execute on function public.can_read_receipt(text) from public, anon;
revoke execute on function public.person_owner_name(uuid) from public, anon;
grant execute on function public.person_owner_name(uuid) to authenticated;
grant execute on function public.my_group_ids() to authenticated;
grant execute on function public.visible_transaction_ids() to authenticated;
grant execute on function public.can_see_transaction(uuid) to authenticated;
grant execute on function public.visible_person_ids() to authenticated;
grant execute on function public.visible_subcategory_ids() to authenticated;
grant execute on function public.visible_category_ids() to authenticated;
grant execute on function public.can_read_receipt(text) to authenticated;

revoke execute on function public.request_link(uuid, text) from public, anon;
revoke execute on function public.create_invite(uuid) from public, anon;
revoke execute on function public.accept_link(uuid, text, uuid) from public, anon;
revoke execute on function public.decline_link(uuid) from public, anon;
revoke execute on function public.cancel_link(uuid) from public, anon;
revoke execute on function public.merge_people(uuid, uuid) from public, anon;
revoke execute on function public.disconnect(uuid) from public, anon;
grant execute on function public.disconnect(uuid) to authenticated;
revoke execute on function public.visible_shared_ids() from public, anon;
grant execute on function public.request_link(uuid, text) to authenticated;
grant execute on function public.create_invite(uuid) to authenticated;
grant execute on function public.accept_link(uuid, text, uuid) to authenticated;
grant execute on function public.decline_link(uuid) to authenticated;
grant execute on function public.cancel_link(uuid) to authenticated;
grant execute on function public.merge_people(uuid, uuid) to authenticated;
grant execute on function public.visible_shared_ids() to authenticated;
