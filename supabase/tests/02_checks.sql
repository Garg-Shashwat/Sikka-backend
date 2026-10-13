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
\echo request to an email without an account succeeds the same way (no account probing)
select request_link('aaaaaaaa-0000-0000-0000-000000000002', 'nobody@x.com') is not null as sent_to_unknown_email;
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
\echo code already used: rejected (returned, so the attempt is counted)
select accept_link(null, :'code', null) as reused_code;
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

-- ===========================================================================
\echo ======== security fixes ========
\echo EXPECT ERROR: users cannot change the profile email copy
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
update users set email = 'b@x.com' where id = '33333333-3333-3333-3333-333333333333';
update users set name = 'Chintu C' where id = '33333333-3333-3333-3333-333333333333';
select name as c_can_rename from users;
\echo EXPECT ERROR: Me cannot be turned into someone else
update people set is_self = false where is_self;
\echo a request goes to the verified login email only
reset role; update auth.users set email_confirmed_at = null where id = '33333333-3333-3333-3333-333333333333'; set role authenticated;
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
insert into people (id, owner_user_id, name) values ('ffffffff-0000-0000-0000-000000000005','22222222-2222-2222-2222-222222222222','C maybe');
select request_link('ffffffff-0000-0000-0000-000000000005', 'c@x.com') as req_c \gset
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select count(*) as unverified_c_sees_request from links where id = :'req_c';
reset role; update auth.users set email_confirmed_at = now() where id = '33333333-3333-3333-3333-333333333333'; set role authenticated;
select count(*) as verified_c_sees_request, max(invite_code) as invite_code_hidden from links where id = :'req_c';
select decline_link(:'req_c');
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
\echo EXPECT ERROR: asking again right after a decline
select request_link('ffffffff-0000-0000-0000-000000000005', 'c@x.com');

\echo --- consent: B (connected to A only) cannot drag C in
-- A puts Chintu (C) and Bunty (B) on one expense, so B can see Chintu
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select upsert_transaction(jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000010','type','expense','amount',300,'date','2026-10-06',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',300)),
  'shares', jsonb_build_array(jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000002','amount',150), jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000003','amount',150))));
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
\echo EXPECT ERROR: B puts Chintu on a new expense
select upsert_transaction(jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000011','type','expense','amount',100,'date','2026-10-06',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'b_me','amount',100)),
  'shares', jsonb_build_array(jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000003','amount',100))));
\echo EXPECT ERROR: B puts Chintu in a group of B
select upsert_group(jsonb_build_object('id','cccccccc-0000-0000-0000-0000000000b2','name','B group','member_ids',jsonb_build_array(:'b_me','aaaaaaaa-0000-0000-0000-000000000003')));
\echo B can still edit the expense Chintu is already on (keeps Chintu)
select upsert_transaction(jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000010','type','expense','amount',400,'date','2026-10-06',
  'payers', jsonb_build_array(jsonb_build_object('person_id','ffffffff-0000-0000-0000-000000000001','amount',400)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'b_me','amount',200), jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000003','amount',200))));
select amount as b_edit_saved from transactions where id = 'eeeeeeee-0000-0000-0000-000000000010';

\echo --- history: every change is recorded and visible to those involved
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select action, changed_by = '22222222-2222-2222-2222-222222222222' as by_b, before->>'amount' as before_amt, after->>'amount' as after_amt
  from transaction_history where transaction_id = 'eeeeeeee-0000-0000-0000-000000000010' order by id;
\echo EXPECT ERROR: history cannot be written directly
insert into transaction_history (transaction_id, action) values ('eeeeeeee-0000-0000-0000-000000000010', 'edited');

\echo --- disconnect: A disconnects B
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select count(*) as b_sees_before from transactions;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select disconnect('aaaaaaaa-0000-0000-0000-000000000002');
select linked_user_id is null as a_bunty_unlinked from people where id = 'aaaaaaaa-0000-0000-0000-000000000002';
select count(*) as a_still_has_own_txs from transactions where owner_user_id = '11111111-1111-1111-1111-111111111111';
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select (select count(*) from transactions where owner_user_id = '11111111-1111-1111-1111-111111111111') as b_sees_a_txs_after,
       (select count(*) from people where owner_user_id = '11111111-1111-1111-1111-111111111111') as b_sees_a_people_after,
       (select count(*) from transactions where owner_user_id = '22222222-2222-2222-2222-222222222222') as b_keeps_own,
       (select linked_user_id is null from people where id = 'ffffffff-0000-0000-0000-000000000001') as b_person_for_a_unlinked,
       (select status from links where id = :'link_id') as link_status;
\echo EXPECT ERROR: disconnecting twice
select disconnect('ffffffff-0000-0000-0000-000000000001');

\echo --- invite codes: format, expiry, wrong-code limit
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
insert into people (id, owner_user_id, name) values ('aaaaaaaa-0000-0000-0000-000000000009','11111111-1111-1111-1111-111111111111','Later');
select create_invite('aaaaaaaa-0000-0000-0000-000000000009') as code2 \gset
select :'code2' ~ '^[A-HJKMNP-Z2-9]{10}$' as code_format_ok;
reset role; update links set expires_at = now() - interval '1 minute' where invite_code = :'code2'; set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select accept_link(null, :'code2', null) as expired_code;
-- one request per attempt, like the app (C already has 2 wrong attempts: the reused and the expired code)
select accept_link(null, 'WRONGCODE1', null) as wrong_1;
select accept_link(null, 'WRONGCODE2', null) as wrong_2;
select accept_link(null, 'WRONGCODE3', null) as wrong_3;
select accept_link(null, 'WRONGCODE4', null) as wrong_4;
select accept_link(null, 'WRONGCODE5', null) as wrong_5;
select accept_link(null, 'WRONGCODE6', null) as wrong_6;
select accept_link(null, 'WRONGCODE7', null) as wrong_7;
select accept_link(null, 'WRONGCODE8', null) as wrong_8;
\echo EXPECT ERROR: the 11th wrong code within the hour is refused
select accept_link(null, 'WRONG', null);

\echo --- request/invite quota: 20 a day
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
do $$ begin
  for i in 1..25 loop
    insert into people (owner_user_id, name) values ('11111111-1111-1111-1111-111111111111', 'Q' || i);
  end loop;
end $$;
do $$ declare n int := 0; p record; begin
  for p in select id from people where name like 'Q%' order by name loop
    begin perform create_invite(p.id); n := n + 1; exception when others then raise notice 'refused after % more: %', n, sqlerrm; exit; end;
  end loop;
end $$;

-- ===========================================================================
\echo ======== access lists (whitelist / blacklist) ========
reset role;
-- (Existing accounts are copied to the allow list when the migration runs; here users are
-- created after migrating, so the lists start empty.)
select private.allow('a@x.com'); select private.allow('@family.in'); select private.block('bad@family.in');
-- one entry per email: blocking an allowed email switches it
select private.allow('both@x.com'); select private.block('both@x.com');
select count(*) as entries_for_both, max(list) as now_listed from private.access_list where entry = 'both@x.com';
-- an allowed email inside a blocked domain stays blocked
select private.block('@spam.io'); select private.allow('friend@spam.io');
\echo whitelist ON (default)
select e, public.hook_before_user_created(jsonb_build_object('user', jsonb_build_object('email', e))) = '{}'::jsonb as can_sign_up,
       public.hook_custom_access_token(jsonb_build_object('user_id', gen_random_uuid(), 'claims', jsonb_build_object('email', e, 'sub', 'x'))) ? 'claims' as can_sign_in
from unnest(array['a@x.com', 'A@X.com ', 'mom@family.in', 'bad@family.in', 'both@x.com', 'friend@spam.io', 'stranger@x.com', '']) as e;
\echo whitelist OFF
select private.set_whitelist(false);
select e, public.hook_before_user_created(jsonb_build_object('user', jsonb_build_object('email', e))) = '{}'::jsonb as can_sign_up
from unnest(array['stranger@x.com', 'bad@family.in', 'both@x.com', 'a@x.com']) as e;
select private.set_whitelist(true);
\echo the refusal message and that claims pass through unchanged
select public.hook_before_user_created('{"user": {"email": "stranger@x.com"}}') as refusal;
select public.hook_custom_access_token('{"user_id": "11111111-1111-1111-1111-111111111111", "claims": {"email": "a@x.com", "role": "authenticated"}}') as allowed_claims;
\echo email looked up from the account when the token has none
select public.hook_custom_access_token('{"user_id": "11111111-1111-1111-1111-111111111111", "claims": {"role": "authenticated"}}') ? 'claims' as a_by_user_id;
\echo switching back to allow, then removing the entry
select private.allow('both@x.com');
select public.hook_before_user_created('{"user": {"email": "both@x.com"}}') = '{}'::jsonb as both_allowed_again;
select private.unlist('both@x.com');
select public.hook_before_user_created('{"user": {"email": "both@x.com"}}') = '{}'::jsonb as both_after_unlist;
\echo EXPECT ERROR: an invalid entry
select private.allow('not-an-email');
\echo API roles cannot read the lists or call the hooks
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
\echo EXPECT ERROR: authenticated reads the list
select * from private.access_list;
\echo EXPECT ERROR: authenticated calls a hook
select public.hook_custom_access_token('{"user_id": "11111111-1111-1111-1111-111111111111", "claims": {}}');
\echo EXPECT ERROR: authenticated turns the whitelist off
select private.set_whitelist(false);
set role anon;
\echo EXPECT ERROR: anon calls a hook
select public.hook_before_user_created('{"user": {"email": "x@x.com"}}');
reset role;

-- ===========================================================================
\echo ======== account deletion ========
-- K (3333) is connected to A (A's "Chintu"); K adds a shared expense with A and a private one.
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select id as k_me from people where is_self \gset
select id as k_for_a from people where owner_user_id = '33333333-3333-3333-3333-333333333333' and linked_user_id = '11111111-1111-1111-1111-111111111111' \gset
select id as k_sub from subcategories where owner_user_id = '33333333-3333-3333-3333-333333333333' and name = 'Fuel' \gset
select upsert_transaction(jsonb_build_object('id','99999999-0000-0000-0000-000000000001','type','expense','amount',800,'date','2026-10-10','description','K and A taxi','subcategory_id',:'k_sub',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'k_me','amount',800)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'k_me','amount',400), jsonb_build_object('person_id',:'k_for_a','amount',400))));
select upsert_transaction(jsonb_build_object('id','99999999-0000-0000-0000-000000000002','type','expense','amount',100,'date','2026-10-10','description','K private',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'k_me','amount',100)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'k_me','amount',100))));
-- A records an expense with Chintu (K) using one of A's own categories
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select upsert_transaction(jsonb_build_object('id','99999999-0000-0000-0000-000000000003','type','expense','amount',600,'date','2026-10-11','description','A and Chintu lunch','subcategory_id',:'sub_id',
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',600)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'me_id','amount',300), jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000003','amount',300))));
-- A edits K's taxi (A is on it), putting it under A's category
select upsert_transaction(jsonb_build_object('id','99999999-0000-0000-0000-000000000001','type','expense','amount',800,'date','2026-10-10','description','K and A taxi','subcategory_id',:'sub_id',
  'payers', jsonb_build_array(jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000003','amount',800)),
  'shares', jsonb_build_array(jsonb_build_object('person_id','aaaaaaaa-0000-0000-0000-000000000003','amount',400), jsonb_build_object('person_id',:'me_id','amount',400))));
\echo K deletes the account
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select delete_my_account();
reset role;
select (select count(*) from auth.users where id = '33333333-3333-3333-3333-333333333333') as k_auth_rows,
       (select count(*) from users where id = '33333333-3333-3333-3333-333333333333') as k_profile,
       (select count(*) from people where owner_user_id = '33333333-3333-3333-3333-333333333333') as k_people,
       (select count(*) from transactions where owner_user_id = '33333333-3333-3333-3333-333333333333') as k_txs,
       (select count(*) from categories where owner_user_id = '33333333-3333-3333-3333-333333333333') as k_categories,
       (select count(*) from links where from_user = '33333333-3333-3333-3333-333333333333' or to_user = '33333333-3333-3333-3333-333333333333') as k_links;
\echo A keeps the lunch, with Chintu as a plain name
select t.description, p.name, p.linked_user_id is null as plain
from transactions t join transaction_shares s on s.transaction_id = t.id join people p on p.id = s.person_id
where t.id = '99999999-0000-0000-0000-000000000003' order by p.name;
\echo the account email can sign up again later (nothing left behind)
select count(*) as leftovers from people where linked_user_id = '33333333-3333-3333-3333-333333333333';
\echo EXPECT ERROR: anon cannot delete accounts
set role anon;
select delete_my_account();
reset role;

-- ===========================================================================
\echo ======== starter categories (new accounts) ========
reset role;
insert into auth.users (id, email) values ('88888888-8888-8888-8888-888888888888', 'fresh@x.com');
select c.name as category, c.icon, string_agg(s.name, ', ' order by s.created_at, s.name) filter (where not s.is_category_default) as subcategories,
       count(*) filter (where s.is_category_default) as default_rows
from categories c join subcategories s on s.category_id = c.id
where c.owner_user_id = '88888888-8888-8888-8888-888888888888'
group by c.name, c.icon, c.sort_order order by c.sort_order;
select count(*) as fresh_me from people where owner_user_id = '88888888-8888-8888-8888-888888888888' and is_self and linked_user_id = owner_user_id;

-- ===========================================================================
\echo ======== app pushes: upserts of brand-new rows ========
set role authenticated;
select set_config('request.jwt.claim.sub','88888888-8888-8888-8888-888888888888',false);
insert into people (id, owner_user_id, name) values ('88888888-0000-0000-0000-000000000001','88888888-8888-8888-8888-888888888888','New friend')
  on conflict (id) do update set name = excluded.name;
insert into categories (id, owner_user_id, name, icon, color) values ('88888888-0000-0000-0000-000000000002','88888888-8888-8888-8888-888888888888','New category','tag','#888888')
  on conflict (id) do update set name = excluded.name;
insert into subcategories (id, owner_user_id, category_id, name, is_category_default) values ('88888888-0000-0000-0000-000000000003','88888888-8888-8888-8888-888888888888','88888888-0000-0000-0000-000000000002',null,true)
  on conflict (id) do update set name = excluded.name;
insert into tags (id, owner_user_id, name, color) values ('88888888-0000-0000-0000-000000000004','88888888-8888-8888-8888-888888888888','New tag','#888888')
  on conflict (id) do update set name = excluded.name;
select (select count(*) from people where id = '88888888-0000-0000-0000-000000000001') as new_person,
       (select count(*) from categories where id = '88888888-0000-0000-0000-000000000002') as new_category,
       (select count(*) from subcategories where id = '88888888-0000-0000-0000-000000000003') as new_subcategory,
       (select count(*) from tags where id = '88888888-0000-0000-0000-000000000004') as new_tag;
\echo still private: another account sees none of them (0)
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select count(*) as others_see from people where owner_user_id = '88888888-8888-8888-8888-888888888888' and not is_self;
reset role;
\echo EXPECT ERROR: another account cannot take over my new person through an upsert
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
set role authenticated;
insert into people (id, owner_user_id, name) values ('88888888-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Hijacked')
  on conflict (id) do update set name = excluded.name, owner_user_id = excluded.owner_user_id;
\echo EXPECT ERROR: another account cannot take over my new category through an upsert
insert into categories (id, owner_user_id, name, icon, color) values ('88888888-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Hijacked','tag','#000000')
  on conflict (id) do update set name = excluded.name, owner_user_id = excluded.owner_user_id;
\echo EXPECT ERROR: cannot create a person owned by another account
insert into people (id, owner_user_id, name) values ('88888888-0000-0000-0000-000000000009','88888888-8888-8888-8888-888888888888','Planted')
  on conflict (id) do update set name = excluded.name;
\echo EXPECT ERROR: cannot create a subcategory owned by another account
insert into subcategories (id, owner_user_id, category_id, name, is_category_default) values ('88888888-0000-0000-0000-000000000008','88888888-8888-8888-8888-888888888888','88888888-0000-0000-0000-000000000002','Planted',false)
  on conflict (id) do update set name = excluded.name;
\echo unchanged and still invisible to the other account (0 0 0)
select (select count(*) from people where owner_user_id = '88888888-8888-8888-8888-888888888888') as people_seen,
       (select count(*) from categories where owner_user_id = '88888888-8888-8888-8888-888888888888') as categories_seen,
       (select count(*) from subcategories where owner_user_id = '88888888-8888-8888-8888-888888888888') as subcategories_seen;
reset role;
select name, owner_user_id = '88888888-8888-8888-8888-888888888888' as still_owner from people where id = '88888888-0000-0000-0000-000000000001'
union all select name, owner_user_id = '88888888-8888-8888-8888-888888888888' from categories where id = '88888888-0000-0000-0000-000000000002';
select count(*) as planted_rows from (select id from people where id = '88888888-0000-0000-0000-000000000009' union all select id from subcategories where id = '88888888-0000-0000-0000-000000000008') x;

-- ===========================================================================
\echo ======== app sync, every push the app makes (as in mobile/src/sync/engine.ts) ========
set role authenticated;
select set_config('request.jwt.claim.sub','88888888-8888-8888-8888-888888888888',false);
\echo profile
update users set name = 'Fresh', default_currency = 'INR' where id = '88888888-8888-8888-8888-888888888888';
\echo person: create, edit, archive, unarchive
insert into people (id, owner_user_id, name, phone, avatar_url, is_self, created_at, deleted_at) values
  ('88888888-0000-0000-0000-0000000000a1','88888888-8888-8888-8888-888888888888','Asha',null,null,false,now(),null)
  on conflict (id) do update set name = excluded.name, phone = excluded.phone, avatar_url = excluded.avatar_url, is_self = excluded.is_self, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
insert into people (id, owner_user_id, name, phone, avatar_url, is_self, created_at, deleted_at) values
  ('88888888-0000-0000-0000-0000000000a1','88888888-8888-8888-8888-888888888888','Asha K','98',null,false,now(),now())
  on conflict (id) do update set name = excluded.name, phone = excluded.phone, avatar_url = excluded.avatar_url, is_self = excluded.is_self, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
insert into people (id, owner_user_id, name, phone, avatar_url, is_self, created_at, deleted_at) values
  ('88888888-0000-0000-0000-0000000000a1','88888888-8888-8888-8888-888888888888','Asha K','98',null,false,now(),null)
  on conflict (id) do update set name = excluded.name, phone = excluded.phone, avatar_url = excluded.avatar_url, is_self = excluded.is_self, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
\echo category + its default subcategory + a subcategory: create, edit, archive
insert into categories (id, owner_user_id, name, icon, color, sort_order, created_at, deleted_at) values
  ('88888888-0000-0000-0000-0000000000b1','88888888-8888-8888-8888-888888888888','Pets','paw','#123456',99,now(),null)
  on conflict (id) do update set name = excluded.name, icon = excluded.icon, color = excluded.color, sort_order = excluded.sort_order, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
insert into subcategories (id, owner_user_id, category_id, name, is_category_default, created_at, deleted_at) values
  ('88888888-0000-0000-0000-0000000000b2','88888888-8888-8888-8888-888888888888','88888888-0000-0000-0000-0000000000b1',null,true,now(),null)
  on conflict (id) do update set category_id = excluded.category_id, name = excluded.name, is_category_default = excluded.is_category_default, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
insert into subcategories (id, owner_user_id, category_id, name, is_category_default, created_at, deleted_at) values
  ('88888888-0000-0000-0000-0000000000b3','88888888-8888-8888-8888-888888888888','88888888-0000-0000-0000-0000000000b1','Vet',false,now(),null)
  on conflict (id) do update set category_id = excluded.category_id, name = excluded.name, is_category_default = excluded.is_category_default, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
insert into categories (id, owner_user_id, name, icon, color, sort_order, created_at, deleted_at) values
  ('88888888-0000-0000-0000-0000000000b1','88888888-8888-8888-8888-888888888888','Pet care','paw','#654321',99,now(),null)
  on conflict (id) do update set name = excluded.name, icon = excluded.icon, color = excluded.color, sort_order = excluded.sort_order, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
insert into subcategories (id, owner_user_id, category_id, name, is_category_default, created_at, deleted_at) values
  ('88888888-0000-0000-0000-0000000000b4','88888888-8888-8888-8888-888888888888','88888888-0000-0000-0000-0000000000b1','Grooming',false,now(),now())
  on conflict (id) do update set category_id = excluded.category_id, name = excluded.name, is_category_default = excluded.is_category_default, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
\echo tag: create, edit, archive
insert into tags (id, owner_user_id, name, color, emoji, created_at, deleted_at) values
  ('88888888-0000-0000-0000-0000000000c1','88888888-8888-8888-8888-888888888888','Trip','#111111',null,now(),null)
  on conflict (id) do update set name = excluded.name, color = excluded.color, emoji = excluded.emoji, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
insert into tags (id, owner_user_id, name, color, emoji, created_at, deleted_at) values
  ('88888888-0000-0000-0000-0000000000c1','88888888-8888-8888-8888-888888888888','Goa trip','#222222','🏖',now(),now())
  on conflict (id) do update set name = excluded.name, color = excluded.color, emoji = excluded.emoji, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
select id as fresh_me from people where owner_user_id = '88888888-8888-8888-8888-888888888888' and is_self \gset
\echo group with the new person
select upsert_group(jsonb_build_object('id','88888888-0000-0000-0000-0000000000d1','name','Pet parents','member_ids',jsonb_build_array(:'fresh_me','88888888-0000-0000-0000-0000000000a1')));
\echo expense using the new person, subcategory and tag, in the group
select upsert_transaction(jsonb_build_object('id','88888888-0000-0000-0000-0000000000e1','type','expense','amount',2000,'currency','INR','date','2026-10-13','description','Vet visit',
  'subcategory_id','88888888-0000-0000-0000-0000000000b3','group_id','88888888-0000-0000-0000-0000000000d1','tag_ids',jsonb_build_array('88888888-0000-0000-0000-0000000000c1'),
  'payers', jsonb_build_array(jsonb_build_object('person_id',:'fresh_me','amount',2000)),
  'shares', jsonb_build_array(jsonb_build_object('person_id',:'fresh_me','amount',1000), jsonb_build_object('person_id','88888888-0000-0000-0000-0000000000a1','amount',1000))));
\echo receipt on it: create, then delete
insert into attachments (id, owner_user_id, transaction_id, storage_path, mime_type, size_bytes, created_at, deleted_at) values
  ('88888888-0000-0000-0000-0000000000f1','88888888-8888-8888-8888-888888888888','88888888-0000-0000-0000-0000000000e1','88888888-8888-8888-8888-888888888888/r1.jpg','image/jpeg',100,now(),null)
  on conflict (id) do update set transaction_id = excluded.transaction_id, storage_path = excluded.storage_path, mime_type = excluded.mime_type, size_bytes = excluded.size_bytes, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
insert into attachments (id, owner_user_id, transaction_id, storage_path, mime_type, size_bytes, created_at, deleted_at) values
  ('88888888-0000-0000-0000-0000000000f1','88888888-8888-8888-8888-888888888888','88888888-0000-0000-0000-0000000000e1','88888888-8888-8888-8888-888888888888/r1.jpg','image/jpeg',100,now(),now())
  on conflict (id) do update set transaction_id = excluded.transaction_id, storage_path = excluded.storage_path, mime_type = excluded.mime_type, size_bytes = excluded.size_bytes, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
\echo all of it comes back on pull (Asha K live, Pet care, Vet + Grooming archived, Goa trip archived, group of 2, expense with 1 tag, deleted receipt)
select (select p->>'name' from jsonb_array_elements(r->'tables'->'people') p where p->>'id' = '88888888-0000-0000-0000-0000000000a1' and p->>'deleted_at' is null) as person,
       (select c->>'name' from jsonb_array_elements(r->'tables'->'categories') c where c->>'id' = '88888888-0000-0000-0000-0000000000b1') as category,
       (select count(*) from jsonb_array_elements(r->'tables'->'subcategories') s where s->>'category_id' = '88888888-0000-0000-0000-0000000000b1') as subcategories,
       (select (s->>'deleted_at') is not null from jsonb_array_elements(r->'tables'->'subcategories') s where s->>'id' = '88888888-0000-0000-0000-0000000000b4') as grooming_archived,
       (select t->>'name' || case when t->>'deleted_at' is not null then ' (archived)' else '' end from jsonb_array_elements(r->'tables'->'tags') t where t->>'id' = '88888888-0000-0000-0000-0000000000c1') as tag,
       (select jsonb_array_length(g->'group_members') from jsonb_array_elements(r->'tables'->'groups') g where g->>'id' = '88888888-0000-0000-0000-0000000000d1') as group_members,
       (select jsonb_array_length(t->'transaction_tags') from jsonb_array_elements(r->'tables'->'transactions') t where t->>'id' = '88888888-0000-0000-0000-0000000000e1') as tx_tags,
       (select (a->>'deleted_at') is not null from jsonb_array_elements(r->'tables'->'attachments') a where a->>'id' = '88888888-0000-0000-0000-0000000000f1') as receipt_deleted,
       (select u->>'name' from jsonb_array_elements(r->'tables'->'users') u) as profile
from pull_changes('{}') r;
reset role;

-- ===========================================================================
\echo ======== email_status (email-first sign-in) ========
reset role;
insert into auth.users (id, email, email_confirmed_at) values ('99999999-9999-9999-9999-999999999999', 'pending@x.com', null);
set role anon;
\echo account, account (case and spaces ignored), new, new (unconfirmed sign-up), new (empty)
select email_status('a@x.com') as a, email_status('  A@X.com ') as a_mixed, email_status('nobody@x.com') as nobody,
       email_status('pending@x.com') as unconfirmed, email_status(null) as empty;
reset role;
