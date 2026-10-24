-- Step 6, lag in bytes. Needs one value from each side.

-- 1. On the SOURCE:
SELECT pg_current_wal_lsn();

-- 2. On the TARGET, paste the value from step 1:
SELECT '<PUBLISHER_LSN>'::pg_lsn AS publisher_lsn, latest_end_lsn AS subscriber_lsn,
       pg_size_pretty(pg_wal_lsn_diff('<PUBLISHER_LSN>', latest_end_lsn)) AS lag
FROM pg_stat_subscription WHERE relid IS NULL;
