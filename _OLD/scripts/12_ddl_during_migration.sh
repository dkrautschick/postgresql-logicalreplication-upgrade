#!/usr/bin/env bash
# Step 12 (optional, while replication is running): schema change without breaking the stream.
# Logical replication does not replicate DDL. Order of operations for ADDITIVE changes:
#   1. target first  2. source second  3. refresh the subscription so new tables are picked up
# Usage: scripts/12_ddl_during_migration.sh
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

log "1. DDL on the TARGET first (a subscriber that knows more columns than the publisher is fine)"
psql_dst -q -f "$REPO/sql/ddl_add_awards.sql"
ok "target has beers.untappd_score and table awards"

log "2. The same DDL on the SOURCE"
psql_src -q -f "$REPO/sql/ddl_add_awards.sql"
psql_src -q -c "UPDATE beers SET untappd_score = round((3 + random() * 1.8)::numeric, 2);"
psql_src -q -c "INSERT INTO awards (beer_id, award, year) VALUES (5, 'Gold, European Beer Star', 2025), (8, 'Silver, World Beer Cup', 2026), (13, 'Best Bock, Portugal', 2024);"
ok "source has the new column filled and 3 awards"

log "3. Column change arrives on its own; the new TABLE does not until the subscription is refreshed"
sleep 3
echo "  untappd_score values on target: $(q_dst 'SELECT count(untappd_score) FROM beers')"
echo "  rows in awards on target       : $(q_dst 'SELECT count(*) FROM awards')"
echo "  awards in pg_subscription_rel  : $(q_dst "SELECT count(*) FROM pg_subscription_rel WHERE srrelid = 'awards'::regclass")  (0 = not yet subscribed)"

log "4. Refresh the subscription (FOR ALL TABLES publication already includes awards on the source)"
psql_dst -q -c "SELECT * FROM aiven_extras.pg_alter_subscription_refresh_publication('$SUBSCRIPTION', TRUE);"
for _ in $(seq 1 60); do
  STATE="$(q_dst "SELECT srsubstate FROM pg_subscription_rel WHERE srrelid = 'awards'::regclass")"
  [[ "$STATE" == "r" ]] && break; sleep 1
done
ok "awards is in state '${STATE:-?}' on the subscriber"
psql_dst -c "SELECT a.year, b.name, a.award FROM awards a JOIN beers b ON b.id = a.beer_id ORDER BY a.year;"

cat <<'EOT'

  What happens if you get the order wrong (source first, then write to the new column):
  the apply worker fails with "logical replication target relation ... is missing replicated column",
  pg_stat_subscription_stats.apply_error_count goes up, the subscription retries forever, the slot on
  the publisher holds WAL. Fix: run the DDL on the target; the worker picks up where it stopped.
  Destructive changes (DROP COLUMN, type changes, renames) go the other way round: source first, target
  second, and only when the replication has caught up in between. Simplest of all: a DDL freeze for the
  hours the migration takes.
EOT
