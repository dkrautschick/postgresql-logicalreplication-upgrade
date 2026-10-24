-- Step 6. Run on the SOURCE (publisher).

-- The slot: is it active, how much WAL does it hold back? An inactive slot grows until the disk is full.
SELECT slot_name, plugin, active, restart_lsn, confirmed_flush_lsn, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS wal_behind
FROM pg_replication_slots;

-- The walsender's view of the subscriber
-- Aiven: SELECT * FROM aiven_extras.pg_stat_replication_list();
SELECT application_name, state, sent_lsn, write_lsn, flush_lsn, replay_lsn, write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
