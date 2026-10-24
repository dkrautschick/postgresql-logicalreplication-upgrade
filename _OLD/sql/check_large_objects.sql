-- Large objects are invisible to logical replication. Run on BOTH sides to compare.
-- count + a hash over every object's content, ordered by oid (oids are preserved by pg_dump/pg_restore)
SELECT count(*) AS large_objects,
       pg_size_pretty(coalesce(sum(length(lo_get(oid))), 0)) AS total_size,
       coalesce(md5(string_agg(md5(lo_get(oid)), '' ORDER BY oid)), 'empty') AS content_hash
FROM pg_largeobject_metadata;
