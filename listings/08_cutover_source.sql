-- Step 8, on the SOURCE.

-- 1. New sessions on the database become read-only; existing application sessions are terminated.
ALTER DATABASE beerdb SET default_transaction_read_only = on;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE datname = 'beerdb' AND pid <> pg_backend_pid() AND backend_type = 'client backend';
-- (RDS / Cloud SQL / Azure alternative: REVOKE CONNECT ON DATABASE beerdb FROM app_role;)

-- 2. One last marker row; this session overrides the read-only default for exactly this write.
SET default_transaction_read_only = off;
INSERT INTO tap_log(note) VALUES ('cutover-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD"T"HH24MISS"Z"'));

-- Drain check: compare with latest_end_lsn on the target (06_lag_in_bytes.sql); it must be >= this value.
SELECT pg_current_wal_lsn();
