\set ON_ERROR_STOP 0
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111','a@x.com'),('22222222-2222-2222-2222-222222222222','b@x.com');
select (select count(*) from public.people) people, (select count(*) from public.categories) cats, (select count(*) from public.subcategories) subs;
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select count(*) as my_people from people;
-- create Mom and an expense
insert into people (id, owner_user_id, name) values ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Mom');
select id as me_id from people where is_self \gset
select id as sub_id from subcategories where name='Restaurant' \gset
select upsert_transaction(jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000001','type','expense','amount',300000,'date','2026-10-01','description','Dinner','subcategory_id',:'sub_id',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',300000)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',150000), jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000001','amount',150000))));
-- idempotent retry
select upsert_transaction(jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000001','type','expense','amount',300000,'date','2026-10-01','description','Dinner','subcategory_id',:'sub_id',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',300000)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',150000), jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000001','amount',150000))));
select count(*) txs, (select count(*) from transaction_shares) shares from transactions;
\echo EXPECT ERROR: share total mismatch
select upsert_transaction(jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000002','type','expense','amount',1000,'date','2026-10-01',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',1000)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',900))));
\echo EXPECT ERROR: second default subcategory
insert into subcategories (owner_user_id, category_id, name, is_category_default) select owner_user_id, category_id, null, true from subcategories where name='Restaurant';
\echo EXPECT ERROR: hard delete of person blocked (no rows deleted)
delete from people where name='Mom';
select count(*) as mom_still_there from people where name='Mom';
-- group
select upsert_group(jsonb_build_object('id','cccccccc-0000-0000-0000-000000000001','name','Family','member_ids',jsonb_build_array(:'me_id','aaaaaaaa-0000-0000-0000-000000000001')));
select count(*) members from group_members;
-- user B
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select count(*) as b_sees_txs from transactions;
select count(*) as b_sees_people from people;
\echo EXPECT ERROR: B overwriting A transaction
select id as b_me from people where is_self \gset
select upsert_transaction(jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000001','type','expense','amount',100,'date','2026-10-01',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'b_me','amount',100)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'b_me','amount',100))));
\echo EXPECT ERROR: B using A person in own transaction
select upsert_transaction(jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000009','type','expense','amount',100,'date','2026-10-01',
  'payers', jsonb_build_array(jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000001','amount',100)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'b_me','amount',100))));
\echo EXPECT ERROR: B adding A person to own group
select upsert_group(jsonb_build_object('id','cccccccc-0000-0000-0000-000000000002','name','X','member_ids',jsonb_build_array('aaaaaaaa-0000-0000-0000-000000000001')));
\echo EXPECT ERROR: storage path for other user
insert into storage.objects (bucket_id, name) values ('receipts','11111111-1111-1111-1111-111111111111/x.jpg');
insert into storage.objects (bucket_id, name) values ('receipts','22222222-2222-2222-2222-222222222222/t/x.jpg');
select count(*) as b_objects from storage.objects;
\echo --- refund + tags as A
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
insert into tags (id, owner_user_id, name) values ('dddddddd-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Goa 2026');
select upsert_transaction(jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000003','type','refund','amount',50000,'date','2026-10-02','refund_of_id','bbbbbbbb-0000-0000-0000-000000000001',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',50000)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',50000)),
  'tag_ids', jsonb_build_array('dddddddd-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000001')));
select type, amount, refund_of_id is not null as has_ref, (select count(*) from transaction_tags tt where tt.transaction_id=t.id) tags from transactions t order by date;
\echo EXPECT ERROR: refund_of on expense
update transactions set refund_of_id = 'bbbbbbbb-0000-0000-0000-000000000003' where id='bbbbbbbb-0000-0000-0000-000000000001';
\echo soft delete
select upsert_transaction(jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000003','type','refund','amount',50000,'date','2026-10-02','deleted_at','2026-10-03T00:00:00Z','refund_of_id','bbbbbbbb-0000-0000-0000-000000000001',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',50000)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',50000))));
select count(*) filter (where deleted_at is not null) deleted from transactions;
\echo EXPECT ERROR: refund without an original expense
select upsert_transaction(jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000004','type','refund','amount',100,'date','2026-10-02',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',100)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',100))));
\echo --- group on transactions
select upsert_transaction(jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000005','type','expense','amount',100,'date','2026-10-02','group_id','cccccccc-0000-0000-0000-000000000001',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',100)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',100))));
select count(*) as group_txs from transactions where group_id = 'cccccccc-0000-0000-0000-000000000001';
\echo EXPECT ERROR: transaction in another user's group
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select upsert_transaction(jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000006','type','expense','amount',100,'date','2026-10-02','group_id','cccccccc-0000-0000-0000-000000000001',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'b_me','amount',100)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'b_me','amount',100))));
\echo --- pull_changes
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select (select count(*) from jsonb_object_keys(r->'tables')) as tables,
       jsonb_array_length(r->'tables'->'people') as people,
       jsonb_array_length(r->'tables'->'transactions') as txs,
       jsonb_array_length(r->'tables'->'users') as users,
       r->'more' as more
  from pull_changes('{}') r;
select jsonb_array_length(t->'transaction_shares') as shares_on_first_tx, t ? 'updated_at' as has_ts
  from pull_changes('{}') r, jsonb_array_elements(r->'tables'->'transactions') t limit 1;
select jsonb_array_length(g->'group_members') as group_members from pull_changes('{}') r, jsonb_array_elements(r->'tables'->'groups') g;
\echo paging by 5 over categories collects every row exactly once
do $$
declare cur jsonb := '{}'; r jsonb; seen int := 0; last jsonb; pages int := 0;
begin
  loop
    r := pull_changes(cur, 5);
    pages := pages + 1;
    seen := seen + jsonb_array_length(r->'tables'->'categories');
    last := r->'tables'->'categories'->-1;
    if last is not null then cur := cur || jsonb_build_object('categories', jsonb_build_object('ts', last->>'updated_at', 'id', last->>'id')); end if;
    exit when jsonb_array_length(r->'tables'->'categories') < 5 or pages > 20;
  end loop;
  raise notice 'categories seen % of %, pages %', seen, (select count(*) from categories), pages;
end $$;
\echo nothing new after the latest cursor
select jsonb_array_length(r->'tables'->'people') as people_after
  from pull_changes(jsonb_build_object('people', jsonb_build_object('ts', (select max(updated_at) from people)::text, 'id', 'ffffffff-ffff-ffff-ffff-ffffffffffff'))) r;
\echo user B sees none of A
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select jsonb_array_length(r->'tables'->'transactions') as b_txs, jsonb_array_length(r->'tables'->'people') as b_people from pull_changes('{}') r;
