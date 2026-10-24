#!/usr/bin/env bash
# Step 11 (part of the cutover): copy large objects, which logical replication never touches.
# Run it AFTER writes on the source have stopped (08_cutover.sh calls it at the right moment).
# Usage: scripts/11_copy_large_objects.sh [--check-only]
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"
need pg_dump; need pg_restore

show_lo_state() {
  log "Large objects on both sides"
  paste <(echo "SOURCE"; psql_src -qtA -c "$(cat "$REPO/sql/check_large_objects.sql")") \
        <(echo "TARGET"; psql_dst -qtA -c "$(cat "$REPO/sql/check_large_objects.sql")") | column -t -s $'\t'
  echo "  dangling label references on target: $(q_dst "$(cat "$REPO/sql/check_dangling_lo_refs.sql")")"
}

show_lo_state
[[ "${1:-}" == "--check-only" ]] && exit 0

SRC_COUNT="$(q_src 'SELECT count(*) FROM pg_largeobject_metadata')"
if [[ "$SRC_COUNT" == "0" ]]; then ok "no large objects on the source, nothing to do"; exit 0; fi

log "Dumping $SRC_COUNT large objects from the source (data only, no tables, oids preserved)"
LO_DUMP="$REPO/large-objects.dump"
# --exclude-table='*' drops every table/sequence/view from the dump; -b keeps the large objects.
pg_dump "$(svc_uri "$SRC_SERVICE" "$DBNAME")" --format=custom --data-only --exclude-table='*' -b \
  --no-owner --no-privileges --file="$LO_DUMP"
ok "written $LO_DUMP ($(du -h "$LO_DUMP" | cut -f1))"

log "Restoring large objects on the target"
# --clean is not needed: the target has no large objects yet. If you re-run, drop them first:
#   SELECT lo_unlink(oid) FROM pg_largeobject_metadata;
pg_restore --dbname="$(svc_uri "$DST_SERVICE" "$DBNAME")" --data-only --no-owner --no-privileges --exit-on-error "$LO_DUMP"

show_lo_state
SRC_HASH="$(q_src "$(cat "$REPO/sql/check_large_objects.sql")" | cut -d'|' -f3)"
DST_HASH="$(q_dst "$(cat "$REPO/sql/check_large_objects.sql")" | cut -d'|' -f3)"
[[ "$SRC_HASH" == "$DST_HASH" ]] && ok "large object content identical on both sides" || die "large object hashes differ"
