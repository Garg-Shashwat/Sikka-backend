-- Clearer refusal message for sign-up / sign-in. Still the same for every refusal, so it doesn't
-- reveal whether an email is blocked or simply not on the allow list.
create or replace function private.access_denied()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'Access to Sikka is restricted. Please contact your administrator to request access.'))
$$;

revoke execute on function private.access_denied() from public, anon, authenticated;
