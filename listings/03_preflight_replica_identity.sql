-- Step 3, preflight. Run on the SOURCE.

-- Tables with default replica identity and no primary key: UPDATE/DELETE on these cannot be published.
SELECT n.nspname || '.' || c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND c.relreplident = 'd'
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary)
ORDER BY 1;

-- Fix, best option: add a primary key. Demo option: replica identity FULL (whole old row in WAL).
ALTER TABLE tap_log REPLICA IDENTITY FULL;

-- Things logical replication will NOT carry: count them now, handle them at cutover.
SELECT count(*) AS sequences FROM pg_sequences WHERE schemaname NOT IN ('pg_catalog', 'information_schema');
SELECT count(*) AS large_objects FROM pg_largeobject_metadata;
SELECT extname, extversion FROM pg_extension ORDER BY 1;   -- every one must exist on the target version
