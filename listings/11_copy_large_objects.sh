# Step 11: copy large objects (never replicated). Run AFTER writes on the source have stopped.
# --exclude-table='*' drops every table/sequence/view from the dump, -b keeps the large objects, oids are preserved.
pg_dump "<SRC_URI>" --format=custom --data-only --exclude-table='*' -b \
  --no-owner --no-privileges --file=large-objects.dump

pg_restore --dbname="<DST_URI>" --data-only --no-owner --no-privileges --exit-on-error large-objects.dump

# Double check: run 07_verify_large_objects.sql on both sides; count and content_hash must match.
# Re-running? Drop them on the target first: SELECT lo_unlink(oid) FROM pg_largeobject_metadata;
