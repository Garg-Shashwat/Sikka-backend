-- Email-first sign-in: after the user types an email, the app asks whether it already has an
-- account, to show "Password" or "Create account".
--
-- Answers only 'account' or 'new'. It never says which allow/block list an email is on (sign-up
-- keeps refusing non-allowed emails with one message). A sign-up that was never confirmed counts
-- as 'new': it can't sign in, and signing up again sends a fresh code.
--
-- Trade-off (accepted): anyone can learn whether an email uses Sikka. Supabase's sign-up already
-- reveals this (an existing account comes back with no identities), so nothing new is exposed.
-- Supabase stores emails in lower case, so the lookup uses its email index.
create or replace function public.email_status(p_email text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when exists (
      select 1 from auth.users
      where email = lower(btrim(coalesce(p_email, ''))) and email_confirmed_at is not null
    ) then 'account'
    else 'new'
  end
$$;

revoke execute on function public.email_status(text) from public;
grant execute on function public.email_status(text) to anon, authenticated;
