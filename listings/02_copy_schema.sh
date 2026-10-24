# Step 2: schema only, from source to target. Use a pg_dump at least as new as the source server.
# --no-owner --no-privileges because role names differ between providers; re-grant afterwards.
pg_dump "<SRC_URI>" --schema-only --no-owner --no-privileges \
  --no-publications --no-subscriptions > schema-from-source.sql

# Aiven targets: aiven_extras is created explicitly later, drop it from the dump if present
sed -i '/EXTENSION.*aiven_extras/d' schema-from-source.sql

psql "<DST_URI>" -v ON_ERROR_STOP=1 -f schema-from-source.sql
