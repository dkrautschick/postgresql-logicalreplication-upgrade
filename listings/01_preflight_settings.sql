-- Step 1, double check. Run on the SOURCE:
SELECT version();
SHOW wal_level;                         -- must be 'logical' (Aiven: always; RDS/Cloud SQL/Azure: see external_sources.md)
SHOW max_replication_slots;             -- one slot per subscription
SHOW max_wal_senders;                   -- one walsender per subscription

-- Run on the TARGET:
SELECT version();
SHOW max_logical_replication_workers;   -- apply worker + table sync workers
SHOW max_sync_workers_per_subscription; -- how many tables are copied in parallel
