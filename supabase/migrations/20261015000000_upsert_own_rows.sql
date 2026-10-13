-- New people, categories and subcategories were refused when the app pushed them.
--
-- The app pushes these with an upsert (INSERT ... ON CONFLICT DO UPDATE), and for an upsert
-- Postgres also checks the SELECT policy against the row being inserted. Since sharing, those
-- policies were "id in (select public.visible_..._ids())", which reads the table and can't see a
-- row that isn't there yet, so every brand-new record failed with "new row violates row-level
-- security policy" and stayed stuck on the phone. Edits to existing records were unaffected.
--
-- Checking the owner on the row itself works for new rows too; the visible_*_ids() part still
-- covers rows shared by other accounts.

drop policy people_select on public.people;
create policy people_select on public.people for select to authenticated
  using (owner_user_id = (select auth.uid()) or id in (select public.visible_person_ids()));

drop policy categories_select on public.categories;
create policy categories_select on public.categories for select to authenticated
  using (owner_user_id = (select auth.uid()) or id in (select public.visible_category_ids()));

drop policy subcategories_select on public.subcategories;
create policy subcategories_select on public.subcategories for select to authenticated
  using (owner_user_id = (select auth.uid()) or id in (select public.visible_subcategory_ids()));
