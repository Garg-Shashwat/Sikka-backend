# Sikka — backend

Supabase project for Sikka: Postgres schema, Row Level Security, sync RPCs, sharing between accounts, sign-up whitelist/blacklist, account deletion, new-account bootstrap and the receipts storage bucket. The mobile app lives in the separate **mobile** repo (`../mobile`).

```
supabase/config.toml     Supabase CLI config (local dev, auth settings, auth hooks)
supabase/migrations/     schema, RLS, RPCs, triggers, storage policies
supabase/templates/      auth emails (6-digit codes for sign-up and password reset)
supabase/tests/          integrity + RLS checks run against a throwaway Postgres
docs/                    public web pages (privacy policy, account deletion) for GitHub Pages
```

## Deploy to a Supabase project

The hosted project is connected to this repo through Supabase's GitHub integration: **pushing to `main` applies new migrations** automatically (usually within a minute). To deploy by hand instead:

```bash
npx supabase login
npx supabase link --project-ref <your-project-ref>
npx supabase db push
```

Never run `supabase config push`: auth settings (SMTP, templates, hooks) are managed in the dashboard and it would overwrite them. Migrations that have been applied are never edited; changes go in a new migration.

Then set up the auth emails in the dashboard. The app confirms sign-ups and resets passwords with a **6-digit code** typed into the app, not a link: links can't return to an app running in Expo Go, because the auth server always rejects `exp://<LAN IP>` addresses.

1. **Authentication → Emails → Templates → Confirm signup**: set the subject to `Your Sikka confirmation code`, and set the body to the contents of [supabase/templates/confirmation.html](supabase/templates/confirmation.html).
2. **Reset Password** template: set the subject to `Your Sikka password reset code`, and set the body to [supabase/templates/recovery.html](supabase/templates/recovery.html).
3. **Authentication → Sign In / Providers → Email**: keep **Confirm email** on, **Email OTP Length** at 6, and set **Minimum password length** to 8 (the app asks for 8).
4. **Authentication → Rate Limits**: keep the email and verification limits low (family scale: tens per hour).
5. **Authentication → Hooks**: enable the two access-list hooks (see *Who can use Sikka* below).

The built-in email sender allows only a few emails per hour. For real users, set up custom SMTP under **Authentication → Emails → SMTP Settings** (currently Gmail, fine for family use).

Give the mobile app the project URL and publishable key (Project Settings → API Keys).

## Local development

```bash
npx supabase start      # local stack in Docker; prints the URL and keys for the app's .env.local
                        # auth emails (with codes) land in Mailpit, at the URL it prints
npx supabase db reset   # re-apply migrations from scratch
```

## Checks

```bash
supabase/tests/run.sh
```

This applies the migrations to a throwaway Postgres container, using a minimal stub of Supabase's `auth` and `storage` schemas, and runs integrity and RLS checks. Every line marked `EXPECT ERROR` should be followed by an error.

## Data model

One `transactions` table for every type, with `transaction_payers` and `transaction_shares` rows that must each add up to the amount (enforced by a deferred constraint trigger). Money is stored as `bigint` minor units (paise).

| Type       | Payers                 | Shares                              |
| ---------- | ---------------------- | ----------------------------------- |
| expense    | who paid               | who it was for                      |
| income     | who received it        | same person (no effect on balances) |
| settlement | who paid (from)        | who received (to)                   |
| transfer   | who sent (from)        | who received (to)                   |
| refund     | who got the money back | whose cost it reduces; must reference its expense (`refund_of_id`) |

- A transaction stores a single `subcategory_id`. Each category has one `is_category_default` subcategory (name `NULL`) that means "the category itself", so "Food" and "Food → Restaurant" are both one id and a mismatched category/subcategory pair can't be stored.
- **Groups** are saved selections of people. The app copies a group's _current_ members into a transaction's shares, so group changes never rewrite history. `transactions.group_id` records which group a transaction was entered under, which drives the group dashboard and group balances.
- **People** are archived, not deleted (`deleted_at`); there is no delete policy, and foreign keys use `on delete restrict`. The only hard delete is account deletion (below).
- Every row has an `owner_user_id`: the account that created it. Each account has its own categories, subcategories and tags (new accounts get their own copy of the starter categories). Tags are never shown to anyone else; a category's name and icon are readable by others only on shared transactions that use it.
- **Receipts** are files in the private `receipts` bucket under `<user id>/…`. Each account uploads only into its own folder; a receipt can be read by everyone who can see its transaction.

## Who can use Sikka (whitelist / blacklist)

Kept on the server ([migration](supabase/migrations/20261013000000_access_lists.sql)), in the `private` schema that the API can't reach:

- **Whitelist on** (the default): only emails on the allow list can sign up or sign in.
- **Whitelist off**: everyone can, except emails on the block list.
- One list: each email (`asha@gmail.com`) or domain (`@family.in`) has a single entry, marked `allow` or `block`. If an email and its domain disagree, the block wins.
- Everyone who already had an account when this was introduced was added to the allow list.

Enforced by two Supabase Auth hooks: *Before User Created* refuses sign-ups, and *Custom Access Token* refuses every sign-in and token refresh, so a newly blocked person is signed out everywhere within the access-token lifetime (1 hour by default). Refusals all show the same message, so nobody can tell which list they're on.

**One-time setup on the hosted project** (dashboard → Authentication → Hooks):

1. *Before User Created* → Postgres → schema `public`, function `hook_before_user_created`.
2. *Customize Access Token (JWT) Claims* → Postgres → schema `public`, function `hook_custom_access_token`.

Until both are enabled, the lists have no effect.

**Managing the lists** (dashboard → SQL editor):

```sql
select private.allow('asha@gmail.com');            -- or a domain: private.allow('@family.in')
select private.block('spammer@example.com');        -- also switches an allowed entry to blocked
select private.unlist('asha@gmail.com');           -- remove the entry
select private.set_whitelist(false);               -- open to everyone except the block list
select * from private.access_list order by list, entry;
select whitelist_enabled from private.access_settings;
```

## Public pages

[docs/](docs/) holds the privacy policy ([privacy.html](docs/privacy.html)) and the account-deletion page ([delete-account.html](docs/delete-account.html)) required by Google Play. Serve them with GitHub Pages (repo Settings → Pages → `main` / `/docs`); the app links to `https://garg-shashwat.github.io/Sikka-backend/privacy.html`. Replace `SUPPORT_EMAIL` in the pages before release.

## Account deletion

`delete_my_account()` permanently deletes the caller's account and everything it owns (the app first removes the receipt files through the Storage API). Connections are disconnected first, and where other accounts' records mention one of the deleted person's people, those accounts get their own plain copy of that person, so their records stay intact. Google Play also requires a public deletion page: [docs/delete-account.html](docs/delete-account.html).

## Sharing between accounts

A shared ledger, like Splitwise ([migration](supabase/migrations/20261009000000_sharing.sql)):

- **Who is who.** `people.linked_user_id` says which Sikka account a person is. Everyone's "Me" is linked to themselves (and can't stop being "Me"). Other links are made only with consent through `public.links`, and a trigger refuses `linked_user_id` changes made through the API roles:
  - `request_link(person, email)` addresses a request to an email. It behaves the same whether or not the email has an account (no account probing); whoever signs in with that *verified* login email (from `auth.users`, never the editable profile) sees it, for 30 days. They accept with `accept_link(link, null, person)` or `decline_link(link)`; asking again after a decline waits 7 days.
  - `create_invite(person)` returns a one-time 10-character code (no look-alike characters), valid 7 days, for `accept_link(null, code, person)`. A wrong code returns `invalid_code`; 10 wrong codes in an hour lock code entry for that account.
  - Each account can create 20 requests/invites a day and have 30 waiting. `cancel_link` withdraws one.
  - On accepting, the other side picks which of *their* people the requester is (or creates one), so past records connect.
  - `disconnect(person)` (either side) stops sharing: each side's "Me" on the other's records becomes the plain person, links are marked `disconnected`, and neither sees the other's records any more.
- **Records carry accounts.** `transaction_payers`, `transaction_shares` and `group_members` have a `user_id`, filled by trigger from the person. Apps map accounts onto their own people, so "Asha's Rahul" reads as "Me" on Rahul's phone.
- **Visibility.** You can see a transaction if you created it, are a payer or share in it, or it is in a (not deleted) group you belong to; anyone who can see it can edit or delete it (`upsert_transaction`). Groups are visible to their members and edited only by their creator (`upsert_group`). People and categories that a visible transaction or group refers to are readable (not editable). Tags stay personal: each account sees only its own tags on a shared transaction.
- **Consent for third parties.** A person who stands for an account can only be added to a new expense or a group by someone connected with that account, or (for expenses) inside a group that account is in. People already on an expense can stay when others edit it.
- **History.** Every change made through `upsert_transaction` is recorded in `transaction_history` (who, when, before/after amount, date, description, payers and shares; never notes). Readable by everyone who can see the transaction; nobody can write it directly.
- **Profiles.** Users can update their name and settings, but not `users.email`.
- **Merging.** `merge_people(from, into)` moves everything recorded for one of my people onto another and archives the first. A connection moves along with it.
- **Newly visible history.** When something becomes visible (a link is accepted, someone joins a group), the affected rows get a fresh `updated_at` so incremental pulls pick them up. `visible_shared_ids()` lists the shared rows still visible, so apps can drop ones that no longer are (e.g. after leaving a group).

## Sync contract

- IDs are UUIDs generated on the client, so retried writes are idempotent.
- `updated_at` is always set by the server (trigger) and is the client's pull cursor. `pull_changes(p_since, p_limit)` returns changes for all tables in one call, using keyset paging on `(updated_at, id)`.
- Deletions are `deleted_at` tombstones so they reach other devices.
- `upsert_transaction(p jsonb)` and `upsert_group(p jsonb)` write a whole aggregate atomically: the row plus its payers, shares and the caller's tags, or its members. They are `SECURITY DEFINER` with explicit permission checks (there are no direct-write policies on these tables).
- New accounts get a `users` profile, a "Me" person and starter categories from the `on_auth_user_created` trigger (`handle_new_user`; the current list is in [20261014000100_default_categories_v2.sql](supabase/migrations/20261014000100_default_categories_v2.sql)). Changing the list only affects accounts created afterwards.
- Tables are in the `supabase_realtime` publication so other devices get notified to pull. Realtime applies RLS, so apps subscribe without an owner filter and also hear about shared rows and connection requests.
