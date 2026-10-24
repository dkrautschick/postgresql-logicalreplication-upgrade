-- Step 7. Run the SAME statement on BOTH sides and compare. Equal count + equal hash = equal content.
-- Replace tastings with each table; the ORDER BY on the row's text form makes the hash deterministic.
SELECT count(*) AS rows,
       coalesce(md5(string_agg(t::text, E'\n' ORDER BY t::text)), 'empty') AS content_hash
FROM tastings t;

-- All tables in one go (generate the statements, then run them on both sides)
SELECT format('SELECT %L AS t, count(*), coalesce(md5(string_agg(x::text, E''\n'' ORDER BY x::text)),''empty'') FROM %I.%I x;',
              n.nspname || '.' || c.relname, n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1;
