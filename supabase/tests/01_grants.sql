-- Like Supabase: tables and functions created in public are granted to the API roles by default,
-- before any migration runs; migrations then revoke what they must (e.g. the profile email column).
alter default privileges in schema public grant select, insert, update, delete on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;
grant select, insert, update, delete on storage.objects to authenticated;
