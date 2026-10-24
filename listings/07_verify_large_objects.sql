-- Step 7. Large objects are NEVER replicated. Run on BOTH sides.
SELECT count(*) AS large_objects,
       pg_size_pretty(coalesce(sum(length(lo_get(oid))), 0)) AS total_size,
       coalesce(md5(string_agg(md5(lo_get(oid)), '' ORDER BY oid)), 'empty') AS content_hash
FROM pg_largeobject_metadata;

-- Rows pointing at a large object this server does not have (target: > 0 until step 11 has run)
SELECT count(*) AS beers_with_missing_label
FROM beers b
WHERE b.label_lo IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM pg_largeobject_metadata m WHERE m.oid = b.label_lo);
