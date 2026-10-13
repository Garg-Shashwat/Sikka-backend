-- Who may use Sikka: an allow list (whitelist), a block list (blacklist) and a switch.
--
--   Whitelist ON  (default): only emails on the allow list may sign up or sign in.
--   Whitelist OFF:           everyone may, except emails on the block list.
--
-- One list: each email ("asha@gmail.com") or domain ("@family.in") has a single entry, marked
-- 'allow' or 'block'. If an email and its domain disagree (e.g. the email is allowed but the
-- domain is blocked), the block wins.
--
-- Enforced by two Supabase Auth hooks (enable them in the dashboard, see README):
--   * Before User Created  → public.hook_before_user_created: refuses the sign-up.
--   * Custom Access Token  → public.hook_custom_access_token: refuses every sign-in and every
--     token refresh, so someone blocked later is signed out within an hour (the access-token
--     lifetime), on every device.
--
-- The lists live in the "private" schema, which the API doesn't expose: only the dashboard /
-- SQL editor can read or change them (see the helper functions at the end).

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table private.access_settings (
  id boolean primary key default true check (id), -- exactly one row
  whitelist_enabled boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into private.access_settings (id) values (true);

create table private.access_list (
  entry text primary key check (entry = lower(btrim(entry)) and entry ~ '^([^@\s]+)?@[^@\s]+\.[^@\s]+$'),
  list text not null check (list in ('allow', 'block')),
  note text,
  created_at timestamptz not null default now()
);

revoke all on all tables in schema private from public, anon, authenticated;

-- Existing accounts keep working when the whitelist goes live.
insert into private.access_list (entry, list, note)
select distinct lower(btrim(email)), 'allow', 'existing account when the whitelist was introduced'
from auth.users
where email is not null and btrim(email) <> ''
on conflict (entry) do nothing;

create or replace function private.is_email_allowed(p_email text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with e as (select lower(btrim(coalesce(p_email, ''))) as email),
  m as (
    select l.list from private.access_list l, e
    where e.email <> '' and (l.entry = e.email or l.entry = '@' || split_part(e.email, '@', 2))
  )
  select case
    when (select email from e) = '' then false
    when exists (select 1 from m where list = 'block') then false
    when (select whitelist_enabled from private.access_settings) then exists (select 1 from m where list = 'allow')
    else true
  end
$$;

-- One message for every refusal, so it doesn't reveal which list (if any) an email is on.
create or replace function private.access_denied()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'This email can’t use Sikka yet. Ask the person who runs it to add you.'))
$$;

-- Auth hook: Before User Created. Input: { "user": { "email": ... }, ... }. Return {} to allow.
create or replace function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if private.is_email_allowed(event -> 'user' ->> 'email') then
    return '{}'::jsonb;
  end if;
  return private.access_denied();
end;
$$;

-- Auth hook: Custom Access Token. Runs on every sign-in and token refresh. Input:
-- { "user_id": ..., "claims": { "email": ..., ... } }. Returns the claims unchanged when allowed.
create or replace function public.hook_custom_access_token(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_email text := coalesce(
    event -> 'claims' ->> 'email',
    (select email from auth.users where id = (event ->> 'user_id')::uuid));
begin
  if private.is_email_allowed(v_email) then
    return jsonb_build_object('claims', event -> 'claims');
  end if;
  return private.access_denied();
end;
$$;

-- Only Supabase Auth may call the hooks; nobody can call them (or read the lists) through the API.
revoke execute on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
revoke execute on function public.hook_custom_access_token(jsonb) from public, anon, authenticated;
revoke execute on function private.is_email_allowed(text) from public, anon, authenticated;
revoke execute on function private.access_denied() from public, anon, authenticated;
grant usage on schema private to supabase_auth_admin;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
grant execute on function public.hook_custom_access_token(jsonb) to supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- Managing the lists (run in the dashboard's SQL editor):
--   select private.allow('asha@gmail.com');          -- or private.allow('@family.in')
--   select private.block('spammer@example.com');      -- switches an allowed entry to blocked
--   select private.unlist('asha@gmail.com');          -- remove the entry
--   select private.set_whitelist(false);              -- open to everyone except the block list
--   select * from private.access_list order by list, entry;
-- ---------------------------------------------------------------------------

create or replace function private.allow(p_entry text, p_note text default null)
returns void
language sql
as $$
  insert into private.access_list (entry, list, note) values (lower(btrim(p_entry)), 'allow', p_note)
  on conflict (entry) do update set list = 'allow', note = coalesce(excluded.note, private.access_list.note);
$$;

create or replace function private.block(p_entry text, p_note text default null)
returns void
language sql
as $$
  insert into private.access_list (entry, list, note) values (lower(btrim(p_entry)), 'block', p_note)
  on conflict (entry) do update set list = 'block', note = coalesce(excluded.note, private.access_list.note);
$$;

create or replace function private.unlist(p_entry text)
returns void
language sql
as $$
  delete from private.access_list where entry = lower(btrim(p_entry));
$$;

create or replace function private.set_whitelist(p_enabled boolean)
returns void
language sql
as $$
  update private.access_settings set whitelist_enabled = p_enabled, updated_at = now();
$$;

revoke execute on function private.allow(text, text) from public, anon, authenticated;
revoke execute on function private.block(text, text) from public, anon, authenticated;
revoke execute on function private.unlist(text) from public, anon, authenticated;
revoke execute on function private.set_whitelist(boolean) from public, anon, authenticated;
