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
- `people.linked_user_id` is reserved for linking a Person to a real Sikka account later. It isn't used yet.
- Every row has an `owner_user_id`. Phase 1 policies only allow the owner; future sharing can widen the policies without reshaping the data.

## Sync contract

- IDs are UUIDs generated on the client, so retried writes are idempotent.
- `updated_at` is always set by the server (trigger) and is the client's pull cursor. `pull_changes(p_since, p_limit)` returns changes for all tables in one call, using keyset paging on `(updated_at, id)`.
- Deletions are `deleted_at` tombstones so they reach other devices.
- `upsert_transaction(p jsonb)` and `upsert_group(p jsonb)` write a whole aggregate atomically: the row plus its payers, shares and tags, or its members. They run as `SECURITY INVOKER`, so RLS still applies.
- New accounts get a `users` profile, a "Me" person and starter categories from the `on_auth_user_created` trigger.
- Tables are in the `supabase_realtime` publication so other devices get notified to pull.
