-- One request per sync instead of one per table.
--
-- pull_changes returns every row of the caller's data changed since the given per-table cursors,
-- in the same shape the REST API returns (transactions include payers/shares/tags, groups include
-- members), so the app applies them exactly as before.
--
--   p_since: { "<table>": { "ts": <updated_at>, "id": <uuid or null> } | null, ... }
--            A missing/null entry means "everything". Rows come after (ts, id) in (updated_at, id)
--            order, so paging never skips rows that share a timestamp.
--   result:  { "tables": { "<table>": [rows...] }, "more": <true if any table hit p_limit> }
--
-- SECURITY INVOKER: RLS still applies; the owner filter is there so the (owner, updated_at)
-- indexes are used.

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
      ('users', 'id', 'to_jsonb(t)'),
      ('people', 'owner_user_id', 'to_jsonb(t)'),
      ('categories', 'owner_user_id', 'to_jsonb(t)'),
      ('subcategories', 'owner_user_id', 'to_jsonb(t)'),
      ('tags', 'owner_user_id', 'to_jsonb(t)'),
      ('groups', 'owner_user_id',
        $e$to_jsonb(t) || jsonb_build_object('group_members', coalesce(
          (select jsonb_agg(jsonb_build_object('person_id', m.person_id)) from public.group_members m where m.group_id = t.id), '[]'))$e$),
      ('transactions', 'owner_user_id',
        $e$to_jsonb(t) || jsonb_build_object(
          'transaction_payers', coalesce(
            (select jsonb_agg(jsonb_build_object('person_id', x.person_id, 'amount', x.amount)) from public.transaction_payers x where x.transaction_id = t.id), '[]'),
          'transaction_shares', coalesce(
            (select jsonb_agg(jsonb_build_object('person_id', x.person_id, 'amount', x.amount)) from public.transaction_shares x where x.transaction_id = t.id), '[]'),
          'transaction_tags', coalesce(
            (select jsonb_agg(jsonb_build_object('tag_id', x.tag_id)) from public.transaction_tags x where x.transaction_id = t.id), '[]'))$e$),
      ('attachments', 'owner_user_id', 'to_jsonb(t)')
    ) as s(tbl, owner_col, expr)
  loop
    since_ts := (p_since -> spec.tbl ->> 'ts')::timestamptz;
    since_id := coalesce((p_since -> spec.tbl ->> 'id')::uuid, '00000000-0000-0000-0000-000000000000'::uuid);

    execute format(
      'select coalesce(jsonb_agg(x.r order by x.updated_at, x.id), ''[]''::jsonb), count(*)::int from (
         select t.updated_at, t.id, %s as r
         from public.%I t
         where t.%I = $1 and ($2::timestamptz is null or (t.updated_at, t.id) > ($2, $3))
         order by t.updated_at, t.id
         limit $4
       ) x',
      spec.expr, spec.tbl, spec.owner_col)
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

revoke execute on function public.pull_changes(jsonb, int) from public, anon;
grant execute on function public.pull_changes(jsonb, int) to authenticated;
