# Sikka — backend

Supabase project for Sikka: Postgres schema, Row Level Security, sync RPCs, new-account bootstrap and the receipts storage bucket. The mobile app lives in the separate **mobile** repo (`../mobile`).

```
supabase/config.toml     Supabase CLI config (local dev, auth settings)
supabase/migrations/     schema, RLS, RPCs, triggers, storage policies
supabase/templates/      auth emails (6-digit codes for sign-up and password reset)
supabase/tests/          integrity + RLS checks run against a throwaway Postgres
```

## Deploy to a Supabase project

```bash
npx supabase login
npx supabase link --project-ref <your-project-ref>
npx supabase db push
```

Then set up the auth emails in the dashboard. The app confirms sign-ups and resets passwords with a **6-digit code** typed into the app, not a link: links can't return to an app running in Expo Go, because the auth server always rejects `exp://<LAN IP>` addresses.

1. **Authentication → Emails → Templates → Confirm signup**: set the subject to `Your Sikka confirmation code`, and set the body to the contents of [supabase/templates/confirmation.html](supabase/templates/confirmation.html).
2. **Reset Password** template: set the subject to `Your Sikka password reset code`, and set the body to [supabase/templates/recovery.html](supabase/templates/recovery.html).
3. **Authentication → Sign In / Providers → Email**: keep **Confirm email** on and **Email OTP Length** at 6.

The built-in email sender allows only a few emails per hour. For real users, set up custom SMTP under **Authentication → Emails → SMTP Settings**.

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
- **People** are archived, never deleted (`deleted_at`); there is no delete policy, and foreign keys use `on delete restrict`.
- Every row has an `owner_user_id`: the account that created it. Categories, subcategories and tags are always private; new accounts get their own copy of the starter categories.

## Sharing between accounts

A shared ledger, like Splitwise ([migration](supabase/migrations/20261009000000_sharing.sql)):

- **Who is who.** `people.linked_user_id` says which Sikka account a person is. Everyone's "Me" is linked to themselves. Other links are made only with consent through `public.links`: `request_link(person, email)` and the other side calls `accept_link(link, null, person)`, or `create_invite(person)` returns a code for `accept_link(null, code, person)`. On accepting, they choose which of *their* people the requester is (or create one), so both sides' past records connect. `decline_link` and `cancel_link` close requests. A trigger stops `linked_user_id` being set any other way.
- **Records carry accounts.** `transaction_payers`, `transaction_shares` and `group_members` have a `user_id`, filled by trigger from the person. Apps map accounts onto their own people, so "Asha's Rahul" reads as "Me" on Rahul's phone.
- **Visibility.** You can see a transaction if you created it, are a payer or share in it, or it is in a group you belong to; anyone who can see it can edit or delete it (`upsert_transaction`). Groups are visible to their members and edited only by their creator (`upsert_group`). People and categories that a visible transaction or group refers to are readable (not editable). Tags stay personal: each account sees only its own tags on a shared transaction.
- **Merging.** `merge_people(from, into)` moves everything recorded for one of my people onto another and archives the first. A connection moves along with it.
- **Newly visible history.** When something becomes visible (a link is accepted, someone joins a group), the affected rows get a fresh `updated_at` so incremental pulls pick them up. `visible_shared_ids()` lists the shared rows still visible, so apps can drop ones that no longer are (e.g. after leaving a group).

## Sync contract

- IDs are UUIDs generated on the client, so retried writes are idempotent.
- `updated_at` is always set by the server (trigger) and is the client's pull cursor. `pull_changes(p_since, p_limit)` returns changes for all tables in one call, using keyset paging on `(updated_at, id)`.
- Deletions are `deleted_at` tombstones so they reach other devices.
- `upsert_transaction(p jsonb)` and `upsert_group(p jsonb)` write a whole aggregate atomically: the row plus its payers, shares and the caller's tags, or its members. They are `SECURITY DEFINER` with explicit permission checks (there are no direct-write policies on these tables).
- New accounts get a `users` profile, a "Me" person and starter categories from the `on_auth_user_created` trigger.
- Tables are in the `supabase_realtime` publication so other devices get notified to pull. Realtime applies RLS, so apps subscribe without an owner filter and also hear about shared rows and connection requests.
