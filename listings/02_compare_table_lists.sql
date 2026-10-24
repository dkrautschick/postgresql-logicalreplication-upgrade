-- Step 2, double check. Run on BOTH sides and diff the output (psql -qtA).
SELECT n.nspname || '.' || c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1;

-- Target should be empty at this point
SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname;
