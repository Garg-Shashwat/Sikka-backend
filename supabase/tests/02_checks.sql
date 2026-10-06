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
select upsert_transaction(jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000001','type','expense','amount',300000,'date','2026-10-01','refund_of_id','bbbbbbbb-0000-0000-0000-000000000003',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',300000)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',300000))));
\echo direct writes to transactions are not allowed (0 rows)
update transactions set description = 'hacked' where id='bbbbbbbb-0000-0000-0000-000000000001';
select count(*) as hacked from transactions where description = 'hacked';
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
\echo EXPECT ERROR: transaction in a group of another user
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

-- ===========================================================================
\echo ======== sharing ========
reset role;
insert into auth.users (id, email) values ('33333333-3333-3333-3333-333333333333','c@x.com');
set role authenticated;
-- A: Bunty stands for B; a shared dinner
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
insert into people (id, owner_user_id, name) values ('aaaaaaaa-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Bunty');
select upsert_transaction(jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000001','type','expense','amount',1000,'date','2026-10-05','subcategory_id',:'sub_id',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',1000)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',500), jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000002','amount',500))));
\echo EXPECT ERROR: setting linked_user_id directly
update people set linked_user_id = '22222222-2222-2222-2222-222222222222' where id = 'aaaaaaaa-0000-0000-0000-000000000002';
\echo EXPECT ERROR: request to an unknown email
select request_link('aaaaaaaa-0000-0000-0000-000000000002', 'nobody@x.com');
select request_link('aaaaaaaa-0000-0000-0000-000000000002', ' B@X.com ') as link_id \gset
-- B: before accepting sees nothing of A's
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select count(*) as b_txs_before from transactions;
select from_name, status from links;
insert into people (id, owner_user_id, name) values ('ffffffff-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','Shashwat');
select accept_link(:'link_id', null, 'ffffffff-0000-0000-0000-000000000001');
select count(*) as b_txs_after from transactions;
select (select count(*) from transaction_payers where user_id = '11111111-1111-1111-1111-111111111111') as payer_is_a,
       (select count(*) from transaction_shares where user_id = '22222222-2222-2222-2222-222222222222') as share_is_b;
select name from people order by name;
select name as b_sees_category from categories;
select linked_user_id = '11111111-1111-1111-1111-111111111111' as my_person_for_a_linked from people where id = 'ffffffff-0000-0000-0000-000000000001';
\echo EXPECT ERROR: accepting the same request twice
select accept_link(:'link_id', null, null);
-- B edits the shared dinner using own people
insert into tags (id, owner_user_id, name) values ('dddddddd-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','B tag');
select upsert_transaction(jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000001','type','expense','amount',1200,'date','2026-10-05','subcategory_id',:'sub_id',
  'payers', jsonb_build_array(jsonb_build_object('person_id','ffffffff-0000-0000-0000-000000000001','amount',1200)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'b_me','amount',600), jsonb_build_object('person_id','ffffffff-0000-0000-0000-000000000001','amount',600)),
  'tag_ids', jsonb_build_array('dddddddd-0000-0000-0000-000000000002')));
\echo EXPECT ERROR: B using a tag of A
select upsert_transaction(jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000001','type','expense','amount',1200,'date','2026-10-05',
  'payers', jsonb_build_array(jsonb_build_object('person_id','ffffffff-0000-0000-0000-000000000001','amount',1200)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'b_me','amount',1200)),
  'tag_ids', jsonb_build_array('dddddddd-0000-0000-0000-000000000001')));
\echo EXPECT ERROR: B putting Mom (not visible to B) on it
select upsert_transaction(jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000001','type','expense','amount',1200,'date','2026-10-05',
  'payers', jsonb_build_array(jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000001','amount',1200)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'b_me','amount',1200))));
-- A sees B's edit, with the same meaning, and keeps ownership; tags are per account
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select amount, owner_user_id = '11111111-1111-1111-1111-111111111111' as a_still_owner,
       (select count(*) from transaction_tags tt where tt.transaction_id = t.id) as a_sees_tags
  from transactions t where id = 'eeeeeeee-0000-0000-0000-000000000001';
select (select string_agg(user_id::text, ',' order by user_id) from transaction_shares where transaction_id = 'eeeeeeee-0000-0000-0000-000000000001') as share_users;
-- Group: B can't see Family until added
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select count(*) as b_groups_before, (select count(*) from transactions where id = 'bbbbbbbb-0000-0000-0000-000000000005') as b_group_tx_before from groups;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select upsert_group(jsonb_build_object('id','cccccccc-0000-0000-0000-000000000001','name','Family','member_ids',jsonb_build_array(:'me_id','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002')));
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select count(*) as b_groups_after, (select count(*) from transactions where id = 'bbbbbbbb-0000-0000-0000-000000000005') as b_group_tx_after,
       (select count(*) from people where name = 'Mom') as b_sees_mom from groups;
\echo EXPECT ERROR: B renaming the group of A
select upsert_group(jsonb_build_object('id','cccccccc-0000-0000-0000-000000000001','name','Mine now','member_ids',jsonb_build_array(:'b_me')));
-- B adds a group expense including Mom (visible via the group)
select upsert_transaction(jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000002','type','expense','amount',900,'date','2026-10-06','group_id','cccccccc-0000-0000-0000-000000000001',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'b_me','amount',900)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'b_me','amount',300), jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000001','amount',300), jsonb_build_object('person_id','ffffffff-0000-0000-0000-000000000001','amount',300))));
select jsonb_array_length(r->'tables'->'transactions') as b_pull_txs, jsonb_array_length(r->'tables'->'links') as b_pull_links,
       jsonb_array_length(r->'tables'->'categories') as b_pull_categories from pull_changes('{}') r;
select jsonb_array_length(visible_shared_ids()->'transactions') as b_visible_shared_txs;
-- C, connected to nobody, sees nothing
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select (select count(*) from transactions) c_txs, (select count(*) from groups) c_groups, (select count(*) from people) c_people, (select count(*) from links) c_links;
-- Invite code: A invites C
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
insert into people (id, owner_user_id, name) values ('aaaaaaaa-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','Chintu');
select create_invite('aaaaaaaa-0000-0000-0000-000000000003') as code \gset
\echo EXPECT ERROR: own invite code
select accept_link(null, :'code', null);
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select accept_link(null, lower(:'code'), null);
select name as c_person_for_a from people where not is_self;
\echo EXPECT ERROR: code already used
select accept_link(null, :'code', null);
-- Merge: A had an older "Bunty (old)" with history; merging moves it to Bunty, so B sees it
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
insert into people (id, owner_user_id, name) values ('aaaaaaaa-0000-0000-0000-000000000004','11111111-1111-1111-1111-111111111111','Bunty (old)');
select upsert_transaction(jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000003','type','expense','amount',400,'date','2026-09-01',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',400)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',200), jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000004','amount',200))));
select merge_people('aaaaaaaa-0000-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000002');
select (select count(*) from transaction_shares where person_id = 'aaaaaaaa-0000-0000-0000-000000000004') as old_rows_left,
       (select deleted_at is not null from people where id = 'aaaaaaaa-0000-0000-0000-000000000004') as old_archived;
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select count(*) as b_sees_merged_history from transactions where id = 'eeeeeeee-0000-0000-0000-000000000003';
-- Removing B from the group hides group history B isn't part of
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select upsert_group(jsonb_build_object('id','cccccccc-0000-0000-0000-000000000001','name','Family','member_ids',jsonb_build_array(:'me_id','aaaaaaaa-0000-0000-0000-000000000001')));
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select (select count(*) from groups) as b_groups_removed, (select count(*) from transactions where id = 'bbbbbbbb-0000-0000-0000-000000000005') as b_old_group_tx,
       (select count(*) from transactions where id = 'eeeeeeee-0000-0000-0000-000000000002') as b_own_group_tx;
\echo owner names of shared people
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select p->>'name' as name, p->>'owner_name' as owner_name from pull_changes('{}') r, jsonb_array_elements(r->'tables'->'people') p order by 1, 2;
