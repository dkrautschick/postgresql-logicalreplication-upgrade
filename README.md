# One recipe, two jobs: PostgreSQL major upgrades and migrations to Aiven with logical replication

Companion repository for the blog post *"Two elephants, one WAL: upgrade PostgreSQL 15 to 18 or
migrate from RDS, Cloud SQL and Azure to Aiven with logical replication, without a maintenance window"*.

The scripts build a PostgreSQL 15 service and a PostgreSQL 18 service on Aiven, fill the source with a
small craft-beer database `beerdb` (breweries, beers, pubs, tastings, label images as large objects),
and set up a logical replication link between them. Then they generate load, check the replication from
both ends, verify the data, demonstrate a schema change mid-flight, copy the large objects, and perform
the cutover.

**The same scripts migrate a database from outside Aiven** (Amazon RDS, Google Cloud SQL, Azure Database
for PostgreSQL Flexible Server, your own server): set `SOURCE_IS_AIVEN=false` and `SRC_URI` in `.env`
and skip the source half of script 01. A migration is an upgrade where the source happens to live
somewhere else.

## Prerequisites

- [Aiven CLI](https://aiven.io/docs/tools/cli) (`pip install aiven-client`), logged in: `avn user login`
- `psql`, `pg_dump`, `pg_restore` and `pgbench` from a PostgreSQL client package **at least as new as the
  source server** (PostgreSQL 18 client tools talk to every version used here)
- `jq`
- An Aiven project. Two `startup-4` services for an afternoon cost a few euros.

## Quick start

```bash
cp .env.example .env               # set AVN_PROJECT at minimum
scripts/01_create_services.sh       # two services + database 'beerdb' on both   (~5 min)
scripts/02_schema_and_seed.sh       # schema + data on source, schema only on target
scripts/03_setup_publication.sh     # preflight checks, replica identity, CREATE PUBLICATION (source)
scripts/04_setup_subscription.sh    # CREATE SUBSCRIPTION via aiven_extras, wait for initial sync (target)

scripts/05_generate_load.sh 120     # terminal 1: guests rating beers for 2 minutes
scripts/06_check_replication.sh --watch   # terminal 2: slot, lag, per-table state, conflicts
scripts/06_check_replication.sh --ping    # end-to-end latency of one row

scripts/12_ddl_during_migration.sh  # optional: add a column and a table while replication runs
scripts/07_verify_data.sh           # row counts + content hashes, both sides, plus large objects
scripts/08_cutover.sh               # read-only source, drain, copy LOBs, sync sequences, ANALYZE, new URI
scripts/10_reverse_replication.sh   # optional safety net: replicate 18 -> 15 for rollback
scripts/09_cleanup.sh               # drop subscription/slot/publication; TERMINATE=yes also removes services
```

`scripts/11_copy_large_objects.sh` is called by the cutover; run it with `--check-only` any time to see
the large object gap between the two sides.

## Listings: every step as a copy-paste snippet

`listings/` contains the same steps taken apart: one file per step, shell or SQL, with placeholders
(`<SRC_URI>`, `<DST_URI>`, `<AVN_PROJECT>`) instead of variables and no dependency on `00_lib.sh` or
`.env`. Use them to test a single step against your own environment, to adapt a step for a database
that does not look like the demo, or to walk through the procedure by hand in `psql` before you trust
the automation. `listings/README.md` maps every step to its file and gives the run order for a self-test.

## Scaling this up

The scripts move one database with sixteen large objects and thirty thousand rows. The procedure does not
change for a 2 TB database, for 400 tables, or for sixty databases owned by three teams: schema first,
publication, subscription, drain, cutover. What changes is everything around it. Large migrations need an
inventory (databases, extensions, roles, large objects, tables without primary keys), a sequence (which
workloads go first, which share a cutover window), rehearsals against forks or restored backups until the
runbook is boring, explicit rollback criteria, and someone who owns the go decision. Plan for the initial
copy to take as long as a `COPY` of your largest table takes, for WAL retention on the source while it runs,
and for a DDL freeze. The technical core stays what you see in `scripts/` and `listings/`; the project
around it is yours to size.

## What each script double-checks

| Script | Checks |
|---|---|
| `01_create_services.sh` | server versions, `wal_level=logical`, slot and worker limits |
| `02_schema_and_seed.sh` | identical table lists on both sides, target tables empty |
| `03_setup_publication.sh` | tables without replica identity (fixed with `REPLICA IDENTITY FULL`), sequences, large objects, extensions, publication contents |
| `04_setup_subscription.sh` | subscription visible, every table reaches `srsubstate = 'r'`, row counts after copy |
| `06_check_replication.sh` | slot active + WAL retained, walsender state, apply delay, per-table state, `pg_stat_subscription_stats` (conflict counters on PG 18), byte lag, optional round-trip ping |
| `07_verify_data.sh` | per-table `count(*)` and `md5()` over all rows on both sides, sequence values, large object count/size/hash, dangling label references |
| `08_cutover.sh` | final marker row arrived, lag is zero, large objects copied and hashed, sequences synced, `ANALYZE` done, data verified again |
| `09_cleanup.sh` | no orphaned replication slot left on the publisher |
| `11_copy_large_objects.sh` | large object count and content hash identical, no rows pointing at missing objects |
| `12_ddl_during_migration.sh` | new column replicates without action, new table appears only after `pg_alter_subscription_refresh_publication` and reaches `'r'` |

## Layout

```
scripts/   numbered bash scripts, all source scripts/00_lib.sh
sql/       schema, seed data, pgbench load script, check queries, sequence sync, LOB checks, example DDL
listings/  every step as a standalone shell or SQL snippet with placeholders, for copy-paste self-tests
terraform/ optional: create the two services with the Aiven Terraform provider
```

## The demo database

```
breweries ─< beers ─< tastings >─ pubs        beers.label_lo → large object (label image)
                 │                             tap_log: no primary key (on purpose)
                 └─ awards (added mid-flight by script 12)
batch_number_seq: standalone sequence
tastings.price_per_litre_cents: STORED generated column
```

## Notes and gotchas

- **No superuser on managed PostgreSQL.** `CREATE SUBSCRIPTION`, `CREATE PUBLICATION FOR ALL TABLES` and
  `ALTER SUBSCRIPTION ... REFRESH PUBLICATION` need superuser in vanilla PostgreSQL. Aiven ships the open
  source `aiven_extras` extension, whose functions run those statements for you.
- **DDL is not replicated.** Additive changes: target first, source second, then
  `SELECT aiven_extras.pg_alter_subscription_refresh_publication('sub', true);` for new tables.
  Destructive changes: source first, target second, after the lag is zero. Or freeze DDL for the duration.
  Script 12 shows the additive case and what breaks when the order is wrong.
- **Large objects are not replicated.** `pg_largeobject` is a system catalog and never part of a
  publication. Script 11 moves them with `pg_dump --data-only --exclude-table='*' -b` and `pg_restore`,
  with oids preserved so `beers.label_lo` still points at the right label. It must run after writes stop.
- **Sequences are not replicated before PostgreSQL 19.** `08_cutover.sh` copies them with `setval()`.
- **An inactive replication slot fills the publisher's disk.** `09_cleanup.sh` makes sure none is left behind.
  Aiven recreates slots after failover and maintenance, but not after an in-place major version upgrade.
- **Read-only trick at cutover** uses `ALTER DATABASE ... SET default_transaction_read_only = on`. It only
  affects new sessions, which is why the script also terminates existing application sessions. A logical
  replication apply worker is a normal session too, so `10_reverse_replication.sh` resets it.
- **External sources:** RDS needs `rds.logical_replication = 1`, Cloud SQL `cloudsql.logical_decoding = on`,
  Azure Flexible Server `wal_level = logical` plus the `REPLICATION` attribute on the user. All require a
  restart. The source firewall must accept connections from the Aiven service (consider Aiven static IPs
  if you need stable addresses to allow-list).
- **Alternative with less typing:** Aiven's built-in migration (`avn service update -c migration.host=...`,
  console: *Import database*) runs `aiven-db-migrate`, which uses logical replication under the hood and
  falls back to `pg_dump` where it cannot. The scripts here show what happens underneath.

## License

MIT. Use, copy, break, improve. Drink responsibly.
