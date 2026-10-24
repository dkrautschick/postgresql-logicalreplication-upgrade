-- Rows that point to a large object that does not exist on this server.
-- On the target this is > 0 until 11_copy_large_objects.sh has run.
SELECT count(*) AS beers_with_missing_label
FROM beers b
WHERE b.label_lo IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM pg_largeobject_metadata m WHERE m.oid = b.label_lo);
