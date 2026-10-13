-- Account deletion (required by Google Play for apps with sign-up).
--
-- delete_my_account() permanently deletes the caller's account and everything it owns: profile,
-- people, groups, categories, tags, transactions (with their payers/shares/tags/history) and
-- attachment records. Receipt files are removed by the app through the Storage API first
-- (Supabase doesn't allow deleting storage objects with SQL).
--
-- Other accounts keep their own records intact:
--   * every connection is disconnected first (their records show me as a plain name);
--   * where their records still mention one of my people (e.g. my "Mom" on their group expense),
--     that person is replaced in their records by a copy in their own account.

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v record;
  v_copy uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  -- 1. Stop sharing with everyone I'm connected to.
  for v in
    select id from public.people where owner_user_id = v_uid and not is_self and linked_user_id is not null
  loop
    perform public.disconnect(v.id);
  end loop;

  -- 2. My people still mentioned in other accounts' records get a copy in those accounts.
  for v in
    select distinct t.owner_user_id as owner, p.id as person, p.name, p.is_self
    from public.people p
    join (
      select person_id, transaction_id from public.transaction_payers
      union select person_id, transaction_id from public.transaction_shares
    ) a on a.person_id = p.id
    join public.transactions t on t.id = a.transaction_id
    where p.owner_user_id = v_uid and t.owner_user_id <> v_uid
    union
    select distinct g.owner_user_id, p.id, p.name, p.is_self
    from public.people p
    join public.group_members m on m.person_id = p.id
    join public.groups g on g.id = m.group_id
    where p.owner_user_id = v_uid and g.owner_user_id <> v_uid
  loop
    insert into public.people (owner_user_id, name)
    values (v.owner, case when v.is_self then coalesce(nullif((select name from public.users where id = v_uid), ''), 'Former member') else v.name end)
    returning id into v_copy;
    perform public.swap_person(v.owner, v.person, v_copy);
  end loop;

  -- 3. Their transactions that use one of my categories keep everything except the category.
  perform public.touch_transactions(array(
    select t.id from public.transactions t join public.subcategories s on s.id = t.subcategory_id
    where s.owner_user_id = v_uid and t.owner_user_id <> v_uid));
  update public.transactions t set subcategory_id = null
  from public.subcategories s
  where s.id = t.subcategory_id and s.owner_user_id = v_uid and t.owner_user_id <> v_uid;

  -- 4. Delete what I own, in an order that respects the "restrict" foreign keys.
  delete from public.transaction_tags where owner_user_id = v_uid;
  delete from public.transactions where owner_user_id = v_uid;          -- payers, shares, history, attachments, refunds of them
  delete from public.groups where owner_user_id = v_uid;                -- members
  delete from public.people where owner_user_id = v_uid;
  delete from public.subcategories where owner_user_id = v_uid;
  delete from public.categories where owner_user_id = v_uid;
  delete from public.tags where owner_user_id = v_uid;
  delete from public.links where from_user = v_uid or to_user = v_uid;
  delete from public.rate_events where user_id = v_uid;

  -- 5. The account itself (and its profile row, by cascade).
  delete from auth.users where id = v_uid;
end;
$$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
