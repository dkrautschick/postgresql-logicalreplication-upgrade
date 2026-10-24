-- Step 8, part 5. Run on the TARGET: a freshly loaded server has no planner statistics.
ANALYZE;

-- Final checks before switching the application
SELECT subname, latest_end_lsn, now() - latest_end_time AS apply_delay FROM pg_stat_subscription WHERE relid IS NULL;
SELECT schemaname, sequencename, last_value FROM pg_sequences ORDER BY 1, 2;
