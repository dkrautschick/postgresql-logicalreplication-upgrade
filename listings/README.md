# Listings: every step as a standalone snippet

The numbered scripts in `scripts/` automate the whole demo. The files in this folder are the same
steps taken apart: one snippet per step, with placeholders instead of variables, so you can paste a
single step into your own terminal or `psql` session, adapt it to your environment, and test it in
isolation. Nothing here depends on `00_lib.sh` or `.env`.

Placeholders used throughout:

| Placeholder | Meaning |
|---|---|
| `<SRC_URI>` | `postgres://user:pw@host:port/beerdb?sslmode=require` of the source (publisher) |
| `<DST_URI>` | the same for the target (subscriber) |
| `<AVN_PROJECT>` | your Aiven project name |
| `<SRC_HOST>`, `<SRC_PORT>`, `<SRC_USER>`, `<SRC_PASSWORD>` | source connection details for `CREATE SUBSCRIPTION` |

| Step | Where to run | File |
|---|---|---|
| 1 | shell | `01_create_services.sh` |
| 1 | both | `01_preflight_settings.sql` |
| 2 | shell | `02_copy_schema.sh` |
| 2 | both | `02_compare_table_lists.sql` |
| 3 | source | `03_preflight_replica_identity.sql`, `03_create_publication.sql` |
| 4 | target | `04_create_subscription.sql`, `04_wait_for_sync.sql` |
| 5 | shell | `05_load.sh` (+ `../sql/load.pgbench`) |
| 6 | source | `06_publisher_checks.sql` |
| 6 | target | `06_subscriber_checks.sql` |
| 6 | both | `06_lag_in_bytes.sql`, `06_ping.sh` |
| 7 | both | `07_verify_table.sql`, `07_verify_sequences.sql`, `07_verify_large_objects.sql` |
| 8 | source + target | `08_cutover.sh`, `08_cutover_source.sql`, `08_cutover_sequences.sql`, `08_cutover_target.sql` |
| 9 | target + source | `09_cleanup.sql` |
| 10 | target + source | `10_reverse_replication.sql` |
| 11 | shell | `11_copy_large_objects.sh` |
| 12 | both | `12_ddl_during_migration.sql` |
| external | source | `external_sources.md` (RDS, Cloud SQL, Azure, self-managed) |
| alternative | shell | `aiven_builtin_migration.sh` (`aiven-db-migrate` via the Aiven CLI) |

Run order for a self-test: 1, 2, 3, 4, then 5 and 6 side by side, 7, optionally 12, 8 (which uses 11), 10 if you want a rollback path, 9.
