-- Step 6. Run on the TARGET (subscriber).

-- Apply worker: what has arrived, what has been applied, how far behind
SELECT subname, pid, received_lsn, latest_end_lsn, last_msg_receipt_time, latest_end_time,
       now() - latest_end_time AS apply_delay
FROM pg_stat_subscription WHERE relid IS NULL;

-- Per-table state, all should be 'r'
SELECT srrelid::regclass AS table_name, srsubstate FROM pg_subscription_rel ORDER BY 1;

-- Errors and conflicts (PostgreSQL 18 adds the confl_* columns)
SELECT * FROM pg_stat_subscription_stats;
