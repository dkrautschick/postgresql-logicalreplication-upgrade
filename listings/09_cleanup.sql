-- Step 9. First on the TARGET: drop the subscription (drops the slot on the publisher as well).
SELECT * FROM aiven_extras.pg_drop_subscription('sub_beerdb_from_pg15');

-- Then on the SOURCE: make sure no orphaned slot keeps WAL. This should NOT list your slot any more.
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS wal_behind
FROM pg_replication_slots;
-- If it is still there:
-- SELECT pg_drop_replication_slot('slot_beerdb_to_pg18');

DROP PUBLICATION IF EXISTS pub_beerdb_all;
