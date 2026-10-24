-- Step 4, double check. Run on the TARGET until every table is in state 'r'.
-- i = initializing, d = copying data, f = copy finished, s = synchronized, r = ready (streaming changes)
SELECT srrelid::regclass AS table_name, srsubstate, srsublsn
FROM pg_subscription_rel ORDER BY 1;

SELECT count(*) FILTER (WHERE srsubstate <> 'r') AS not_ready, count(*) AS total FROM pg_subscription_rel;

-- Row counts after the initial copy
SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname;
