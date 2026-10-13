-- New starter categories for new accounts. Existing accounts keep the categories they have
-- (each account owns its copy and may have changed it).
--
-- Changes from the first list:
--   * new: Occasions (weddings, pujas, festivals, functions) and Finance (insurance, EMIs,
--     investment, income tax, fees); Income is dropped (adding income is hidden in the app)
--   * Transport is everyday travel; Travel is everything for a trip (incl. road trips and cabs)
--   * Gifts becomes "Gifts & Donations"; more subcategories in Food, Home, Health, Personal Care
--
-- Icons are SF Symbol names; the app maps them to Android's Material Symbols
-- (mobile/src/features/transactions/categoryIcon.ts).

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_category_id uuid;
  v_cat record;
  v_sub text;
  v_order integer := 0;
begin
  insert into public.users (id, name, email, phone)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'name', ''), split_part(coalesce(new.email, ''), '@', 1)),
    new.email,
    new.phone
  );

  insert into public.people (owner_user_id, name, is_self)
  values (new.id, 'Me', true);

  for v_cat in
    select * from (values
      ('Food', 'fork.knife', '#F97316', array['Groceries', 'Restaurant', 'Delivery', 'Snacks', 'Sweets / Desserts']),
      ('Transport', 'car', '#3B82F6', array['Fuel', 'Public Transport', 'Parking', 'Toll / FASTag', 'Vehicle Maintenance']),
      ('Shopping', 'bag', '#EC4899', array['Clothing', 'Electronics', 'Household']),
      ('Home', 'house', '#8B5CF6', array['Rent', 'Electricity', 'Water', 'Internet', 'Mobile', 'Repairs', 'Domestic Help']),
      ('Health', 'cross.case', '#EF4444', array['Medicine', 'Doctor', 'Tests / Diagnostics', 'Fitness']),
      ('Entertainment', 'film', '#14B8A6', array['Movies', 'Subscriptions', 'Outings', 'Kitty Party']),
      ('Travel', 'airplane', '#0EA5E9', array['Flights', 'Train / Bus', 'Road Trip / Cab', 'Hotel / Stay', 'Sightseeing']),
      ('Education', 'book', '#6366F1', array['Fees', 'Books', 'Courses']),
      ('Personal Care', 'sparkles', '#D946EF', array['Salon', 'Cosmetics', 'Beauty Services']),
      ('Gifts & Donations', 'gift', '#F43F5E', array['Gifts', 'Donations']),
      ('Occasions', 'party.popper', '#EAB308', array['Weddings', 'Puja / Religious Ceremonies', 'Festivals', 'Birthdays / Celebrations', 'Family Functions']),
      ('Finance', 'building.columns', '#22C55E', array['Insurance', 'Loan / EMI', 'Investment', 'Income Tax', 'Financial Fees']),
      ('Other', 'ellipsis.circle', '#64748B', array[]::text[])
    ) as c(name, icon, color, subs)
  loop
    insert into public.categories (owner_user_id, name, icon, color, sort_order)
    values (new.id, v_cat.name, v_cat.icon, v_cat.color, v_order)
    returning id into v_category_id;
    v_order := v_order + 1;

    insert into public.subcategories (owner_user_id, category_id, name, is_category_default)
    values (new.id, v_category_id, null, true);

    foreach v_sub in array v_cat.subs loop
      insert into public.subcategories (owner_user_id, category_id, name, is_category_default)
      values (new.id, v_category_id, v_sub, false);
    end loop;
  end loop;

  return new;
end;
$$;
