# Move the elephant, keep the lights on

### How to upgrade PostgreSQL to a new major version, or migrate from RDS, Cloud SQL and Azure to Aiven, with seconds of downtime: one logical replication recipe, a numbered script for every step and not a drop of beer spilled

*All scripts in this post live in the companion repository [dkrautschick/postgresql-logicalreplication-upgrade](https://github.com/dkrautschick/postgresql-logicalreplication-upgrade). Every step references a numbered script you can run against your own Aiven project, and the `listings/` folder has each step as a standalone snippet for copy-paste self-tests. The demo database is `beerdb`, a small craft-beer database, because every example database should contain at least one Doppelbock.*

## Shrink the maintenance window to seconds

You can upgrade PostgreSQL® to a new major version, or move a database from RDS, Cloud SQL or Azure to Aiven, and keep downtime to the seconds it takes to drain the last changes and reconnect your application. This post shows how, with a numbered script for every step. The demo upgrades PostgreSQL 15 to 18, but the method does not depend on those two numbers: it works for any upgrade from PostgreSQL 10 (the first release with built-in logical replication) or newer to a later version. If your source meets the preconditions, `avn service update -c migration.*` does the same job in one command, powered by [aiven-db-migrate](https://aiven.io/docs/products/postgresql/howto/migrate-aiven-db-migrate) (more on that below). The scripts are for when it does not.

The clock is real. PostgreSQL 14 reaches end of life on 12 November 2026, and 15 follows in November 2027. After end of life the PostgreSQL community stops publishing fixes, so Aiven can no longer support that version and the upgrade falls to you. The question is never *if* you upgrade. It is how many minutes of "we're sorry, we'll be right back" you are willing to put in front of your users.

The classic answer, `pg_upgrade`, is fast and well tested. On Aiven it is a single click (or `avn service update -c pg_version=NEW_VERSION`) and finishes in about a minute for small databases. But it has two properties that make architects nervous: the database is unavailable while it runs, and the upgrade is one-way. Your only route back is restoring a backup or a fork, and you lose every write made since.

Logical replication offers a different deal. You build the new server next to the old one, let it catch up while production keeps running, verify everything at your own pace, and then flip a connection string. The old server stays intact as a rollback.

**Logical replication does not care where the old server is.** To the subscriber on the new version (PostgreSQL 18 in our demo), a publisher on an older Aiven service (PostgreSQL 15 in our demo), an Amazon RDS instance, a Google Cloud SQL instance, an Azure Flexible Server or a box under somebody's desk all look the same: a hostname, a port, a publication. The procedure for a major upgrade and the procedure for a migration to Aiven are the same procedure. Only the source changes. Every script and every check in this post works for both, and the repository has a switch for it.

We start with what logical replication is and what it refuses to carry (DDL and large objects). Then we walk through a full upgrade on Aiven, from PostgreSQL 15 to 18 in our demo, with a check at every step, because "it replicated" and "the data is correct" are two different sentences.

## Physical versus logical: photocopier versus phone call

PostgreSQL has two kinds of replication, and the names are only mildly helpful.

**Physical (streaming) replication** ships the write-ahead log (WAL), byte for byte, to a standby that replays it. The standby is a block-level clone of the primary: same major version, same architecture, same everything, down to the dead tuples and the bloat. It is the photocopier of replication. It copies the whole book including the beer stains, it is fast, it is boring, and boring is what you want from high availability. Aiven's own HA standbys and read replicas work this way.

**Logical replication** decodes the same WAL into *row changes* ("row 42 in `tastings` now has rating 5") and sends those to a subscriber that applies them as ordinary SQL. It is the phone call: "Hi, tasting 42 got upgraded to five stars." The subscriber does not need to be the same version. It does not need to be the same instance type, the same cloud, or the same provider. It can hold other tables, other indexes, other data. It can be a PostgreSQL 18 server listening to a PostgreSQL 15 server, or an Aiven service listening to RDS.

|                     | Physical / streaming         | Logical                                                     |
|---------------------|------------------------------|-------------------------------------------------------------|
| What travels        | WAL bytes                    | Decoded row changes (INSERT, UPDATE, DELETE, TRUNCATE)      |
| Granularity         | Whole cluster                | Per database, per table, even per row filter or column list |
| Versions            | Identical major version      | Any supported combination, including old → new              |
| Providers           | Same binaries, same provider | Any PostgreSQL that can reach any other PostgreSQL          |
| Target is           | Read-only clone              | Normal, writable database                                   |
| DDL                 | Replicated (it is just WAL)  | **Not replicated**: you manage the schema                   |
| Large objects       | Replicated                   | **Never replicated**: you copy them                         |
| Sequences           | Replicated                   | Not replicated before PostgreSQL 19                         |
| Needs on the target | Nothing but disk             | Matching tables, extensions, replica identities             |
| Typical use         | HA, read replicas, PITR      | Upgrades, migrations, consolidation, selective sync, CDC    |

The last row is the point. Streaming replication keeps a copy alive. Logical replication moves a database somewhere else while it is running.

## A short history, so you know whose shoulders you are standing on

Logical replication in PostgreSQL did not appear in one release. It took about fifteen years and several generations of tools.

- **2004: Slony-I.** Trigger-based. Every change fired a trigger that wrote to a queue table, and daemons shipped the queue around. It worked, it was a common way to do major upgrades for a decade, and nobody who ran it misses it.
- **Londiste (Skype) and Bucardo** followed the same trigger-based idea with different trade-offs. Bucardo did multi-master, which mostly taught the community why multi-master is hard.
- **2014, PostgreSQL 9.4: logical decoding.** Andres Freund and others added the infrastructure to turn WAL into a stream of logical changes via output plugins. No triggers, no queue tables, no write amplification. `test_decoding` and later `wal2json` showed what was possible, and every CDC tool you know (Debezium, for example) sits on this layer.
- **2016: pglogical** (2ndQuadrant) packaged logical decoding into a usable replication extension and became the prototype for what came next.
- **2017, PostgreSQL 10: built-in logical replication.** `CREATE PUBLICATION` on the source, `CREATE SUBSCRIPTION` on the target, done. Aiven shipped support a year later together with the `aiven_extras` extension, because `CREATE SUBSCRIPTION` needs superuser and a managed platform does not hand out superuser.

Since then every release has added something:

| Version     | Logical replication additions                                                                                                                                                                               |
|-------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 11          | TRUNCATE is replicated                                                                                                                                                                                      |
| 13          | Partitioned tables can publish via the partition root                                                                                                                                                       |
| 14          | Streaming of large in-progress transactions, binary transfer mode                                                                                                                                           |
| 15          | Row filters, column lists, `FOR TABLES IN SCHEMA`                                                                                                                                                           |
| 16          | Logical decoding from a standby, parallel apply of large transactions, `origin = none` for bidirectional setups, non-superuser subscription owners via `pg_create_subscription`                             |
| 17          | Failover slots (slots survive a primary failover), `pg_createsubscriber` to turn a physical standby into a logical replica, `pg_upgrade` preserves slots and subscriptions                                  |
| 18          | Generated columns, conflict logging and statistics, `streaming = parallel` by default, two-phase commit toggle on existing subscriptions, `idle_replication_slot_timeout`, `max_active_replication_origins` |
| 19 (RC 1)   | Sequence replication, `ALL TABLES EXCEPT`, `retain_dead_tuples` for `update_deleted` conflict detection, automatic logical WAL level, subscriptions via `postgres_fdw` servers                              |

We come back to 18 and 19 at the end. First, the upgrade. Or the migration. Same thing.

## Three ways to upgrade, and the one that also migrates

| Method                                   | Downtime                                      | Rollback                                   | Works across providers         | Effort |
|------------------------------------------|-----------------------------------------------|--------------------------------------------|--------------------------------|--------|
| `pg_dump` / `pg_restore`                 | Hours for anything serious                    | Trivial (old server untouched)             | Yes                            | Low    |
| In-place `pg_upgrade` (Aiven: one click) | Seconds to minutes, unreadable during the run | Restore from a backup or fork              | No                             | Lowest |
| Logical replication                      | Application reconnect                         | Old server intact, optionally kept in sync | **Yes, and that is the point** | Medium |

Aiven's in-place upgrade is the right default for a service that is already on Aiven and can take a short interruption. `pg_upgrade --check` runs first, the whole thing usually takes under a minute on small databases, and you can rehearse it on a fork.

Reach for logical replication when the interruption is not acceptable, when you want a rehearsal with real traffic, when you need a rollback path, or when the source is not on Aiven yet. That last case is the migration story, and it uses the same scripts.

## What Aiven does for you, and what it does not

A few platform facts before we start typing:

- `wal_level` is `logical` on every Aiven for PostgreSQL service. Nothing to configure, no restart.
- `aiven_extras` is preinstalled. Its functions run the superuser-only statements (`CREATE SUBSCRIPTION`, `CREATE PUBLICATION FOR ALL TABLES`, `ALTER SUBSCRIPTION ... REFRESH PUBLICATION`) on your behalf.
- Replication slots are recreated after failovers and maintenance updates. On Aiven they are *not* carried over an in-place major version upgrade, so finish logical migrations before you upgrade a publisher in place.
- Aiven's built-in migration (`avn service update -c migration.host=... -c migration.method=replication`, or *Import database* in the console) wraps all of this into one command via [`aiven-db-migrate`](https://aiven.io/docs/products/postgresql/howto/migrate-aiven-db-migrate) (official guide). It is the fast path. This post shows the slow path so you understand what the fast path does, and so you can adapt it when your situation does not fit the wizard.

## The two things logical replication refuses to carry: DDL and large objects

Everybody reads "logical replication replicates your data" and stops. The next sentence in the manual is the one that matters, so here it is in bold: **logical replication replicates row changes in tables, and nothing else.** Two consequences hit every real migration.

### DDL: the schema is your job

No `CREATE TABLE`, no `ALTER TABLE`, no `CREATE INDEX` travels over the link. The target needs the full schema before the first row arrives, which is why step 2 below is a `pg_dump --schema-only`.

Declare a DDL freeze for the hours the migration takes. It is cheaper than the choreography. If you cannot freeze, every schema change has to happen on both sides, in the right order:

| Change                                  | Order                                                                       | Why                                                                                                                                                                                |
|-----------------------------------------|-----------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Add a column, add a table, add an index | **Target first**, then source, then refresh the subscription for new tables | A subscriber that knows more columns than the publisher is fine (extra columns get defaults). A publisher that sends a column the subscriber does not have stops the apply worker. |
| Drop a column, drop a table             | **Source first**, wait for lag = 0, then target                             | Otherwise the publisher still sends changes for something the subscriber already dropped.                                                                                          |
| Change a type, rename                   | Freeze. Do it before or after the migration.                                | Both orders break something.                                                                                                                                                       |

The repository has `scripts/12_ddl_during_migration.sh`, which adds a column (`beers.untappd_score`) and a table (`awards`) while replication runs, in the right order, and shows the one extra step new tables need:

```
-- on the target, after the DDL exists on both sides
SELECT aiven_extras.pg_alter_subscription_refresh_publication('sub_beerdb_from_pg15', TRUE);

-- did the new table join the party?
SELECT srrelid::regclass AS table_name, srsubstate
FROM pg_subscription_rel WHERE srrelid = 'awards'::regclass;
```

The column arrives on its own. The table does not: a `FOR ALL TABLES` publication includes it on the publisher immediately, but the subscriber only learns about it from a refresh, which also copies the rows that already exist. If you get the order wrong and write to a new column on the source before the target has it, the apply worker logs `logical replication target relation "public.beers" is missing replicated column`, `pg_stat_subscription_stats.apply_error_count` climbs, and the slot on the publisher starts hoarding WAL. The fix is to run the DDL on the target. The worker retries and picks up where it stopped. Nothing is lost, but nothing moves until you do.

### Large objects: invisible to the publisher

Large objects are not in the publication, so you copy them yourself at cutover.

PostgreSQL's large objects (`lo_create`, `lo_import`, the `oid` column that points at them) live in the system catalog `pg_largeobject`, and system catalogs are never part of a publication. Your `beers.label_lo` column replicates perfectly, with every oid pointing at a label that is not on the new server. The first `lo_get()` after cutover fails, and that is when the problem shows up.

Two checks tell you where you stand, and `scripts/07_verify_data.sh` runs both:

```
-- how many large objects, how big, and a hash over all of their content (run on both sides)
SELECT count(*) AS large_objects,
       pg_size_pretty(coalesce(sum(length(lo_get(oid))), 0)) AS total_size,
       coalesce(md5(string_agg(md5(lo_get(oid)), '' ORDER BY oid)), 'empty') AS content_hash
FROM pg_largeobject_metadata;

-- rows that point at a label this server does not have
SELECT count(*) AS beers_with_missing_label
FROM beers b
WHERE b.label_lo IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM pg_largeobject_metadata m WHERE m.oid = b.label_lo);
```

The fix is `pg_dump` with a filter that drops every table and keeps the large objects, run after writes on the source have stopped, so the labels cannot change behind your back:

```
pg_dump "$SRC_URI" --format=custom --data-only --exclude-table='*' -b --file=large-objects.dump
pg_restore --dbname="$DST_URI" --data-only --no-owner --exit-on-error large-objects.dump
```

`pg_dump` preserves large object oids, so `beers.label_lo` points at the right label on the new server without any update. `scripts/11_copy_large_objects.sh` does this, then re-runs the hash on both sides, and `scripts/08_cutover.sh` calls it at the right moment, between "writes have stopped" and "sequences are synced". If you have many gigabytes of large objects, this step defines your downtime, and it is a good argument for moving them to `bytea` or object storage before you migrate rather than after. If you have none, the script says so and leaves.

A third, smaller item in the same family: **sequences.** Identity columns and serials keep working on the target, but their sequences start where the empty target started. You sync them at cutover (step 8 below). PostgreSQL 19 replicates them natively.

## The demo: PostgreSQL 15 → 18 (or anywhere → Aiven) in a dozen scripts

The versions are examples. For any other upgrade path the steps stay identical and only the version numbers change.

The repository builds `beerdb`, a small craft-beer database: eight breweries with names only a DBA could love (WAL Street Brewery, Vacuum Full Brewing, Nullpointer Ales), sixteen beers from Kölsch 9.4 to Streaming Stout, five pubs, 30,000 tastings, a keg log with no primary key, a brew batch sequence, a stored generated column for the price per litre, and a label image per beer stored as a large object. A demo without the annoying parts teaches nothing.

### 1. Two services, one command each

```
avn service create --project $AVN_PROJECT --service-type pg --plan startup-4 \
  --cloud google-europe-west1 -c pg_version=15 pg-source-15
avn service create --project $AVN_PROJECT --service-type pg --plan startup-4 \
  --cloud google-europe-west1 -c pg_version=18 pg-target-18
avn service wait --project $AVN_PROJECT pg-source-15
avn service wait --project $AVN_PROJECT pg-target-18
```

`scripts/01_create_services.sh` does this, creates the `beerdb` database on both, and then checks what it created:

```
SELECT version();                           -- on both
SHOW wal_level;                             -- source: must be 'logical'
SHOW max_replication_slots;                 -- source: one per subscription
SHOW max_wal_senders;                       -- source: one per subscription
SHOW max_logical_replication_workers;       -- target: apply + sync workers
SHOW max_sync_workers_per_subscription;     -- target: parallel initial copy
```

The script refuses to continue if `wal_level` is anything but `logical`, which is exactly the check that saves you an hour when the source is RDS. **Migrating instead of upgrading?** Set `SOURCE_IS_AIVEN=false` and `SRC_URI=postgres://...` in `.env`. The script then creates only the target and runs the same checks against your existing server.

### 2. Schema over, data stays

```
pg_dump "$SRC_URI" --schema-only --no-owner --no-privileges \
  --no-publications --no-subscriptions > schema-from-source.sql
psql "$DST_URI" -f schema-from-source.sql
```

`scripts/02_schema_and_seed.sh` seeds the source, dumps the schema with a `pg_dump` at least as new as the source server, and applies it on the target. It uses `--no-owner --no-privileges` because role names rarely survive a change of provider (RDS has `rds_superuser`, Aiven has `avnadmin`), so re-grant your application roles afterwards. Then the double check:

```
-- same statement on both sides, output diffed
SELECT n.nspname || '.' || c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema')
ORDER BY 1;
```

An empty diff means the two sides have the same shape, with no content yet. That is what we want before the copy.

### 3. Publish (and find the table without a primary key first)

`scripts/03_setup_publication.sh` starts with the preflight that finds `tap_log`:

```
-- tables that cannot replicate UPDATE/DELETE: default replica identity and no primary key
SELECT n.nspname || '.' || c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND c.relreplident = 'd'
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary);

-- the things replication will not carry, counted
SELECT count(*) FROM pg_sequences WHERE schemaname NOT IN ('pg_catalog','information_schema');
SELECT count(*) FROM pg_largeobject_metadata;
SELECT extname, extversion FROM pg_extension;
```

An empty result from the first query means every table has a primary key or a replica identity. In the demo it returns `tap_log`, so the script applies `ALTER TABLE tap_log REPLICA IDENTITY FULL` (in a real migration you add a primary key instead, because `FULL` writes the entire old row into WAL on every change and makes the subscriber scan for it). It also warns loudly about the sixteen large objects (we deal with them at cutover in step 8), and then publishes:

```
CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;
SELECT aiven_extras.pg_create_publication_for_all_tables(
  'pub_beerdb_all', 'INSERT,UPDATE,DELETE,TRUNCATE');

-- what is in it?
SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = 'pub_beerdb_all';
```

On a non-Aiven source the same script runs plain `CREATE PUBLICATION pub_beerdb_all FOR ALL TABLES`, which `rds_superuser`, `cloudsqlsuperuser` and `azure_pg_admin` are allowed to do.

### 4. Subscribe, then wait for every table to say "r"

```
CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;
SELECT aiven_extras.pg_create_subscription(
  'sub_beerdb_from_pg15',
  'host=pg-source-15-....aivencloud.com port=12345 dbname=beerdb user=avnadmin password=... sslmode=require',
  'pub_beerdb_all',
  'slot_beerdb_to_pg18',
  TRUE,   -- create the slot on the publisher
  TRUE);  -- copy_data: snapshot every table first, then stream
```

The connection string carries a password. PostgreSQL 19 can take these details from a `postgres_fdw` server instead (see below), so the password stops living in the subscription.

For a migration the connection string is simply your RDS, Cloud SQL or Azure endpoint. `scripts/04_setup_subscription.sh` builds it from `avn service get --json` (or takes `SRC_URI`), creates the subscription, and polls until every table is live:

```
-- pg_subscription is superuser-only; aiven_extras wraps it
SELECT subname, subenabled, subslotname, subpublications
FROM aiven_extras.pg_list_all_subscriptions();

-- i = initializing, d = copying data, f = copy finished, s = synchronized, r = ready and streaming
SELECT srrelid::regclass AS table_name, srsubstate, srsublsn
FROM pg_subscription_rel ORDER BY 1;
```

Only `r` means "live". You will watch these states during a large migration, because the initial copy is a plain `COPY` per table. Plan on it taking about as long as a plain `COPY` of your largest table over your network link. `max_sync_workers_per_subscription` copies several tables in parallel.

### 5. Load, because a quiet database proves nothing

Run `scripts/05_generate_load.sh 120 4` (120 seconds, 4 clients). It runs `pgbench` with a custom script: a guest rates a beer (insert into `tastings`), the beer's check-in counter goes up (update `beers`), an older tasting gets a better rating (update), the keg log gets a line (insert into the table without a primary key), and a brew batch number is consumed from the sequence. Run it in one terminal and keep the next script open in another.

### 6. Check from both ends

`scripts/06_check_replication.sh --watch` refreshes every five seconds and shows the things you will be asked about in a go/no-go meeting. On the publisher:

```
-- is the slot active, and how much WAL is it holding back?
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS wal_behind
FROM pg_replication_slots;

-- the walsender's view (Aiven: aiven_extras.pg_stat_replication_list(); elsewhere: pg_stat_replication)
SELECT application_name, state, sent_lsn, flush_lsn, replay_lsn, replay_lag
FROM pg_stat_replication;
```

On the subscriber:

```
-- how far behind is the apply worker?
SELECT subname, received_lsn, latest_end_lsn, now() - latest_end_time AS apply_delay
FROM pg_stat_subscription WHERE relid IS NULL;

-- anything failing? (PostgreSQL 18 adds the confl_* columns)
SELECT subname, apply_error_count, sync_error_count,
       confl_insert_exists, confl_update_missing, confl_delete_missing
FROM pg_stat_subscription_stats;
```

For most readers the `wal_behind` column in the first query is the lag number you need. If you want the exact byte lag, it takes an LSN from each side:

```
-- publisher
SELECT pg_current_wal_lsn();
-- subscriber, with the value from above pasted in
SELECT pg_size_pretty(pg_wal_lsn_diff('0/1A2B3C4D', latest_end_lsn)) AS lag
FROM pg_stat_subscription WHERE relid IS NULL;
```

The slot query is the one to internalize. A replication slot makes the publisher keep every WAL segment the subscriber has not confirmed. If the subscriber goes away and the slot stays, `wal_behind` grows until the publisher's disk is full and the publisher stops accepting writes. That is a well-known way for logical replication to take down a production database, and it is entirely self-inflicted. In a migration the publisher is your *current production system*, so this matters twice. `scripts/09_cleanup.sh` exists for this reason.

For live demos there is `--ping`: it inserts a marker row into `tap_log` on the source and times how long until it appears on the target. On two `startup-4` services in the same region the marker row shows up in well under a second, which ends the "is it real-time?" discussion.

### 7. Verify the content, not just the counts

`scripts/07_verify_data.sh` runs the same statement for every table on both sides and compares:

```
SELECT count(*), md5(string_agg(t::text, E'\n' ORDER BY t::text)) FROM tastings t;
```

Equal count and equal hash means equal content, including the `price_per_litre_cents` column that the PostgreSQL 18 side computed on its own. Then the script prints every sequence on both sides, and finally the large object check from above. At this point it shows sixteen labels on the source and zero on the target, plus sixteen beers pointing at labels that do not exist yet. That gap is intentional; the cutover closes it.

Run the script while load is active and the table hashes differ, which is correct and a good moment to explain why. Run it after the load stops and they match.

### 8. Cutover: the seconds that matter

Before you start, the go/no-go check is four lines:

- Lag is near zero.
- Every table shows `r`.
- Table hashes match with the load stopped.
- You know how many large objects you have.

`scripts/08_cutover.sh` asks for confirmation and then does six things:

1. **Block writes on the source.** `ALTER DATABASE beerdb SET default_transaction_read_only = on`, then terminate existing application sessions, because the setting only applies to new ones. (On RDS or Cloud SQL you do the same, or revoke `CONNECT` from the application role.)
2. **Drain.** Write one last marker row into `tap_log`, wait until it arrives on the target, then confirm zero lag (query below).
3. **Copy the large objects** with `scripts/11_copy_large_objects.sh`, now that nobody can change them, and compare the content hash on both sides.
4. **Sync sequences.** On the source, `pg_sequences` knows every `last_value`, identity columns included. The script turns that into `setval()` statements and runs them on the target (query below). Skip this and your first `INSERT` on the new server collides with an existing primary key. Everybody does this exactly once.
5. **ANALYZE.** A freshly loaded server has no planner statistics. One `ANALYZE` prevents the "the new version is slower" ticket that is really a "the planner is flying blind" ticket.
6. **Verify again** (step 7, now with matching large objects) and print the new connection string.

The two queries behind steps 2 and 4:

```
-- step 2, drain: publisher LSN vs. what the subscriber has applied (run one on each side)
SELECT pg_current_wal_lsn();                                              -- source
SELECT latest_end_lsn FROM pg_stat_subscription WHERE relid IS NULL;      -- target, must be >= the value above

-- step 4, sequences: run on the source, feed the output to the target
SELECT format('SELECT setval(%L, %s, true);',
              quote_ident(schemaname) || '.' || quote_ident(sequencename), last_value)
FROM pg_sequences
WHERE last_value IS NOT NULL AND schemaname NOT IN ('pg_catalog', 'information_schema');
```

Point your application at `pg-target-18`. Total write unavailability runs from step 1 to the reconnect: usually seconds, plus however long step 3 takes if your labels are real PNGs.

The subscription stays until you decide you are done. If you want a real safety net, `scripts/10_reverse_replication.sh` creates a publication on the new PostgreSQL 18 server and a subscription on the old 15 with `copy_data = FALSE`. Every write that lands on 18 now also lands on 15. Rolling back means pointing the application back. The old server stays a valid fallback only while the reverse subscription runs: once you drop it, new writes on 18 no longer reach 15. Logical replication does not care that the publisher is newer than the subscriber, which gives you a rollback path that `pg_upgrade` cannot offer. In a migration scenario this is the same trick in the other direction: the old RDS instance stays current until you cancel it.

### 9. Clean up, especially the slot

Skipping this step is how a finished migration fills a production disk: an orphaned slot keeps every WAL segment until you drop it. `scripts/09_cleanup.sh` drops the subscription (which drops the slot on the publisher), then checks that nothing was left behind:

```
-- on the publisher: this should not list your slot any more
SELECT slot_name, active, wal_status FROM pg_replication_slots;
```

With `TERMINATE=yes` it also removes both services. The check for orphaned slots is deliberately loud, and on a migration source you run it on the system you are about to decommission, which is exactly when people forget.

## Migrating to Aiven from RDS, Cloud SQL, Azure or anywhere: the same recipe

Nothing in the scripts is Aiven-specific on the source side except the `aiven_extras` call for the publication, and that has a plain-SQL branch. If your source meets the wizard's preconditions, use `avn service update -c migration.*` (shown at the end of this section). If it does not, use the scripts. To migrate from somewhere else:

| Source                                        | Turn on logical WAL                                                                    | Who can create the publication           |
|-----------------------------------------------|----------------------------------------------------------------------------------------|------------------------------------------|
| Amazon RDS / Aurora PostgreSQL                | parameter group `rds.logical_replication = 1`, reboot                                  | `rds_superuser`                          |
| Google Cloud SQL                              | flag `cloudsql.logical_decoding = on`, restart; `ALTER USER ... WITH REPLICATION`      | `cloudsqlsuperuser`                      |
| Azure Database for PostgreSQL Flexible Server | server parameter `wal_level = logical`, restart; `ALTER ROLE ... WITH REPLICATION`     | `azure_pg_admin`                         |
| Self-managed                                  | `wal_level = logical`, `max_replication_slots`, `max_wal_senders`, `pg_hba.conf` entry | any superuser or role with `REPLICATION` |

Then open the source firewall for the Aiven service (Aiven static IPs help if you must allow-list addresses), set `SOURCE_IS_AIVEN=false` and `SRC_URI` in `.env`, and run scripts 02 to 09 unchanged. The DDL freeze and the large object copy apply exactly as above. A migration source is more likely to have both, because it is older.

The version jump costs nothing extra. A PostgreSQL 13 on RDS can publish to PostgreSQL 18 on Aiven in one go; there is no "upgrade in sequence" rule for logical replication the way there is for in-place upgrades. Check extensions first: every extension on the source needs to exist on the target version, and Aiven's extension list per version is public.

Or skip all of it and let Aiven's migration do the same thing. It is built on [aiven-db-migrate](https://aiven.io/docs/products/postgresql/howto/migrate-aiven-db-migrate), and the [official guide](https://aiven.io/docs/products/postgresql/howto/migrate-aiven-db-migrate) covers the CLI and Python routes. The [prerequisites page](https://aiven.io/docs/products/postgresql/concepts/aiven-db-migrate) lists what the tool checks before it starts: PostgreSQL 10 or newer on the source, `wal_level = logical`, and either superuser access or `aiven_extras`.

```
avn service update --project $AVN_PROJECT \
  -c migration.host=mydb.abc123.eu-central-1.rds.amazonaws.com \
  -c migration.port=5432 -c migration.ssl=true \
  -c migration.username=postgres -c migration.password=... \
  -c migration.dbname=beerdb -c migration.method=replication \
  pg-target-18

avn service migration-status --project $AVN_PROJECT pg-target-18
```

The wizard uses logical replication for every database that meets the preconditions and falls back to `pg_dump` for the ones that do not. You now know what those preconditions are, and you know that it does not carry your large objects either. One warning from the docs: running a logical replication migration twice on the same cluster creates duplicate data.

## When the migration is big: scale, planning, and who helps

The demo is deliberately small. Sixteen beers and thirty thousand tastings replicate in seconds; a 2 TB database with 400 tables, or sixty databases spread across three teams, take far longer. The procedure is the same for both: schema first, publication, subscription, drain, cutover. What grows with size is everything around the procedure:

- An inventory of databases, extensions, roles, large objects and tables without primary keys.
- A sequence that decides which workloads move first and which share a cutover window.
- Rehearsals against forks or restored backups until the runbook is boring.
- Explicit rollback criteria, and a person who owns the go decision.
- Capacity for the initial copy, which takes as long as a `COPY` of your largest table, and for the WAL the source retains while it runs.

A large migration is a project with a plan, test runs and a strategy for the order of things. The SQL in this post is the part of that project that does not get harder. For the part that does, Aiven's in-house specialists help with the assessment and the plan, and Aiven's partner network helps with implementations that need more hands than a blog post provides. Talk to them before the first replication slot exists, not after the first disk is full.

## What PostgreSQL 18 changed for logical replication

PostgreSQL 18 (released 25 September 2025; Aiven uses 18 as the default for new services) is a quality-of-life release for replication:

- **Generated columns are published.** Set `publish_generated_columns` on the publication, or use a column list that names them. Before 18 the subscriber had to compute generated columns itself, which works between PostgreSQL servers and fails for everything else. In our 15 → 18 demo the publisher is still 15, so the subscriber computes `price_per_litre_cents`. With an 18 publisher you choose.
- **Conflicts are logged and counted.** `insert_exists`, `update_origin_differs`, `update_exists`, `update_missing`, `delete_origin_differs`, `delete_missing`, `multiple_unique_conflicts`: each gets a log line with the conflicting key and a counter in `pg_stat_subscription_stats`. Diagnosing a stuck subscription went from "read the logs and guess" to "read one row".
- **`streaming = parallel` is the default** for new subscriptions. Parallel workers apply large in-progress transactions instead of spooling them to disk first.
- **`ALTER SUBSCRIPTION ... SET (two_phase = ...)`** works on an existing subscription.
- **`idle_replication_slot_timeout`** invalidates slots nobody has consumed for a while. This is the server-side answer to the disk-full story above.
- **`max_active_replication_origins`** is its own setting, so many subscriptions no longer force a high `max_replication_slots`.
- **`pg_createsubscriber`** gained `--all`, `--clean` and `--enable-two-phase`. It converts a physical standby into a logical subscriber in one step, which is the fastest way to bootstrap a huge logical replica. It needs file-system access to the standby, so it is a self-managed tool. On Aiven the `copy_data` snapshot does the same job over the network.

## What PostgreSQL 19 brings (release candidate 1)

> **Heads-up:** This section reflects PostgreSQL 19 release candidate 1, published on 15 October 2026. Release candidate 2 is planned for 12 November 2026, and general availability is planned for 19 November 2026. We will adjust this section once PostgreSQL 19 is officially released.

Read the list as "in the RC 1 release notes", not "in your production server next week". The logical replication section is substantial:

- **Sequences replicate.** Use `CREATE PUBLICATION ... FOR ALL SEQUENCES`, and `ALTER SUBSCRIPTION ... REFRESH SEQUENCES` syncs their values; `pg_get_sequence_data()` lets you inspect the state. Step 4 of our cutover becomes a one-liner, and the primary key collisions from unsynced sequences go away.
- **`ALL TABLES EXCEPT (...)`** on publications. Finally a way to say "everything but the 400 GB event archive".
- **`retain_dead_tuples`** on subscriptions keeps the information needed to detect `update_deleted` conflicts (an update arriving for a row that was concurrently deleted), with `max_retention_duration` as the safety valve, and a new `update_deleted` counter in `pg_stat_subscription_stats`.
- **Automatic logical WAL level.** With `wal_level = replica`, the server switches to logical decoding when a logical slot needs it, without a restart. `effective_wal_level` reports what is actually in effect. Self-managed sources no longer need the restart that RDS, Cloud SQL and Azure still require today. RC 1 still shipped several fixes for this feature, so test it before you rely on it.
- **`CREATE SUBSCRIPTION ... SERVER`** takes its connection details from a `postgres_fdw` foreign server, so passwords stop living in subscription definitions.
- **Per-subscription `wal_receiver_timeout`**, so a slow cross-region link (hello, migration from another continent) does not force a global setting.
- **`REPACK (CONCURRENTLY)`**, the new command that replaces `VACUUM FULL` and `CLUSTER`, rebuilds a table without an access-exclusive lock. Not replication as such, but it takes its own replication slots (`max_repack_replication_slots`), a sign of how central that machinery has become.
- **Renamed statistics column.** In `pg_stat_subscription_stats`, `sync_error_count` becomes `sync_table_error_count`, and the new `sync_seq_error_count` counts sequence sync errors. If you reuse the step 6 query on a PostgreSQL 19 subscriber, adjust the column name.

Still not on the list: DDL replication and large objects. Plan for both the way this post does.

## The two-minute version for your next architecture call

- Streaming replication copies a cluster; logical replication moves a database. Different tools for different jobs.
- A major version upgrade and a migration to Aiven are the same procedure. Only the source hostname changes.
- The cost is an application reconnect, not a long maintenance window, and the old server stays intact as a rollback, optionally kept in sync.
- Logical replication carries table rows. It does not carry DDL (freeze it, or go target-first for additive changes), large objects (`pg_dump -b` at cutover), or sequences before PostgreSQL 19 (`setval()` at cutover).
- PostgreSQL 18 made conflicts visible; PostgreSQL 19 makes sequences replicate. Both make the method easier, neither changes it.
- On Aiven: `wal_level` is already `logical`, `aiven_extras` replaces superuser, and `avn service update -c migration.*` wraps the whole procedure when the standard case fits (see the [aiven-db-migrate guide](https://aiven.io/docs/products/postgresql/howto/migrate-aiven-db-migrate)). The scripts in the repository are for when it does not.
- Check three things before any migration: replica identities, large objects, and extensions on the target version. Check one thing after: no orphaned slot on the source.

**One challenge this post does not cover: extensions.** Every extension on the source has to exist on the target version, and extensions come with their own versions, dependencies and upgrade paths. That deserves a post of its own, and we will cover it separately in a follow-up on upgrading PostgreSQL extensions.

Builders who run production databases get a rollback path that `pg_upgrade` cannot offer, and now you have the scripts to use it. Clone [the repository](https://github.com/dkrautschick/postgresql-logicalreplication-upgrade), set `AVN_PROJECT` and run script 01. An afternoon and two `startup-4` services later you will have upgraded a database without your users noticing, with every beer label where it belongs. Replication lag is zero, the slot is dropped, and the only thing still catching up is your Doppelbock. Prost.
