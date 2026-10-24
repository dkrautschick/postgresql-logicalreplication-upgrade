# Two elephants, one WAL: upgrade PostgreSQL 15 to 18, or migrate from RDS, Cloud SQL and Azure to Aiven, with logical replication and without a maintenance window

*All scripts in this post live in the companion repository [dkrautschick/postgresql-logicalreplication-upgrade](https://github.com/dkrautschick/postgresql-logicalreplication-upgrade). Every step references a numbered script you can run against your own Aiven project, and the `listings/` folder has each step as a standalone snippet for copy-paste self-tests. The demo database is `beerdb`, a small craft-beer database, because every example database should contain at least one Doppelbock.*

## The maintenance window is a myth

Every PostgreSQL major version lives for five years. PostgreSQL 14 reaches end of life on 12 November 2026, 15 follows in November 2027, and Aiven's EOL dates are identical to upstream, so the platform will eventually upgrade you whether you planned it or not. The question is never *if* you upgrade. It is how many minutes of "we're sorry, we'll be right back" you are willing to put in front of your users.

The classic answer, `pg_upgrade`, is excellent. On Aiven it is a single click (or `avn service update -c pg_version=18`) and finishes in about a minute for small databases. But it has two properties that make architects nervous: the database is unavailable while it runs, and there is no way back. Once you are on 18, you are on 18.

Logical replication offers a different deal. You build the new server next to the old one, let it catch up while production keeps running, verify everything at your own pace, and then flip a connection string. Downtime shrinks to the seconds it takes your application to reconnect. The old server stays intact as a rollback.

And here is the part that makes this interesting for more than version numbers: **logical replication does not care where the old server is.** To a PostgreSQL 18 subscriber on Aiven, a PostgreSQL 15 publisher on Aiven, an Amazon RDS instance, a Google Cloud SQL instance, an Azure Flexible Server or a box under somebody's desk all look the same: a hostname, a port, a publication. The procedure for a major upgrade and the procedure for a migration to Aiven are the same procedure. Only the source changes. Everything in this post, every script and every check, works for both, and the repository has a switch for it.

This post explains what logical replication is, where it came from, how it differs from the streaming replication you already run, what it refuses to replicate (DDL and large objects, and we deal with both), and what PostgreSQL 18 and the upcoming 19 add. Then we upgrade a PostgreSQL 15 service to 18 on Aiven with checks at every step, because "it replicated" and "the data is correct" are two different sentences.

## Physical versus logical: photocopier versus phone call

PostgreSQL has two kinds of replication, and the names are only mildly helpful.

**Physical (streaming) replication** ships the write-ahead log, byte for byte, to a standby that replays it. The standby is a block-level clone of the primary: same major version, same architecture, same everything, down to the dead tuples and the bloat. It is the photocopier of replication. It copies the whole book including the beer stains, it is fast, it is boring, and boring is what you want from high availability. Aiven's own HA standbys and read replicas work this way.

**Logical replication** decodes the same WAL into *row changes* ("row 42 in `tastings` now has rating 5") and sends those to a subscriber that applies them as ordinary SQL. It is the phone call: "Hi, tasting 42 got upgraded to five stars." The subscriber does not need to be the same version. It does not need to be the same instance type, the same cloud, or the same provider. It can hold other tables, other indexes, other data. It can be a PostgreSQL 18 server listening to a PostgreSQL 15 server, or an Aiven service listening to RDS.

| | Physical / streaming | Logical |
|---|---|---|
| What travels | WAL bytes | Decoded row changes (INSERT, UPDATE, DELETE, TRUNCATE) |
| Granularity | Whole cluster | Per database, per table, even per row filter or column list |
| Versions | Identical major version | Any supported combination, including old → new |
| Providers | Same binaries, same provider | Any PostgreSQL that can reach any other PostgreSQL |
| Target is | Read-only clone | Normal, writable database |
| DDL | Replicated (it is just WAL) | **Not replicated**: you manage the schema |
| Large objects | Replicated | **Never replicated**: you copy them |
| Sequences | Replicated | Not replicated before PostgreSQL 19 |
| Needs on the target | Nothing but disk | Matching tables, extensions, replica identities |
| Typical use | HA, read replicas, PITR | Upgrades, migrations, consolidation, selective sync, CDC |

The last row is the point. Streaming replication keeps a copy alive. Logical replication moves a database somewhere else while it is running.

## A short history, so you know whose shoulders you are standing on

Logical replication in PostgreSQL did not appear in one release. It took about fifteen years and several generations of tools.

- **2004: Slony-I.** Trigger-based. Every change fired a trigger that wrote to a queue table, and daemons shipped the queue around. It worked, it was the way to do major upgrades for a decade, and nobody who ran it misses it.
- **Londiste (Skype) and Bucardo** followed the same trigger-based idea with different trade-offs. Bucardo did multi-master, which mostly taught the community why multi-master is hard.
- **2014, PostgreSQL 9.4: logical decoding.** Andres Freund and others added the infrastructure to turn WAL into a stream of logical changes via output plugins. No triggers, no queue tables, no write amplification. `test_decoding` and later `wal2json` showed what was possible, and every CDC tool you know (Debezium, for example) sits on this layer.
- **2016: pglogical** (2ndQuadrant) packaged logical decoding into a usable replication extension and became the prototype for what came next.
- **2017, PostgreSQL 10: built-in logical replication.** `CREATE PUBLICATION` on the source, `CREATE SUBSCRIPTION` on the target, done. Aiven shipped support a year later together with the open source `aiven_extras` extension, because `CREATE SUBSCRIPTION` needs superuser and no sane managed platform hands out superuser.

Since then every release has added something:

| Version | Logical replication additions |
|---|---|
| 11 | TRUNCATE is replicated |
| 13 | Partitioned tables can publish via the partition root |
| 14 | Streaming of large in-progress transactions, binary transfer mode |
| 15 | Row filters, column lists, `FOR TABLES IN SCHEMA` |
| 16 | Logical decoding from a standby, parallel apply of large transactions, `origin = none` for bidirectional setups, non-superuser subscription owners via `pg_create_subscription` |
| 17 | Failover slots (slots survive a primary failover), `pg_createsubscriber` to turn a physical standby into a logical replica, `pg_upgrade` preserves slots and subscriptions |
| 18 | Generated columns, conflict logging and statistics, `streaming = parallel` by default, two-phase commit toggle on existing subscriptions, `idle_replication_slot_timeout`, `max_active_replication_origins` |
| 19 (beta 4) | Sequence replication, `ALL TABLES EXCEPT`, `retain_dead_tuples` for `update_deleted` conflict detection, automatic logical WAL level, subscriptions via `postgres_fdw` servers |

We come back to 18 and 19 at the end. First, the upgrade. Or the migration. Same thing.

## Three ways to upgrade, and the one that also migrates

| Method | Downtime | Rollback | Works across providers | Effort |
|---|---|---|---|---|
| `pg_dump` / `pg_restore` | Hours for anything serious | Trivial (old server untouched) | Yes | Low |
| In-place `pg_upgrade` (Aiven: one click) | Seconds to minutes, unreadable during the run | None | No | Lowest |
| Logical replication | Application reconnect | Old server intact, optionally kept in sync | **Yes, and that is the point** | Medium |

Aiven's in-place upgrade is the right default for a service that is already on Aiven and can take a short interruption: `pg_upgrade --check` runs first, the whole thing usually takes under a minute on small databases, and you can rehearse it on a fork.

Reach for logical replication when the interruption is not fine, when you want a rehearsal with real traffic, when you need a rollback path, or when the source is not on Aiven yet. That last case is the migration story, and it is the same scripts.

## What Aiven does for you, and what it does not

A few platform facts before we start typing:

- `wal_level` is `logical` on every Aiven for PostgreSQL service. Nothing to configure, no restart.
- `aiven_extras` is preinstalled. Its functions run the superuser-only statements (`CREATE SUBSCRIPTION`, `CREATE PUBLICATION FOR ALL TABLES`, `ALTER SUBSCRIPTION ... REFRESH PUBLICATION`) on your behalf.
- Replication slots are recreated after failovers and maintenance updates. They are *not* carried over an in-place major version upgrade, so finish logical migrations before upgrading a publisher in place.
- Aiven's built-in migration (`avn service update -c migration.host=... -c migration.method=replication`, or *Import database* in the console) wraps all of this into one command via `aiven-db-migrate`. It is the fast path. This post shows the slow path so you understand what the fast path does, and so you can adapt it when your situation does not fit the wizard.

## The two things logical replication refuses to carry: DDL and large objects

Everybody reads "logical replication replicates your data" and stops. The next sentence in the manual is the one that matters, so here it is in bold: **logical replication replicates row changes in tables, and nothing else.** Two consequences hit every real migration.

### DDL: the schema is your job

No `CREATE TABLE`, no `ALTER TABLE`, no `CREATE INDEX` travels over the link. The target needs the full schema before the first row arrives, which is why step 2 below is a `pg_dump --schema-only`. During the migration, every schema change has to happen on both sides, in the right order:

| Change | Order | Why |
|---|---|---|
| Add a column, add a table, add an index | **Target first**, then source, then refresh the subscription for new tables | A subscriber that knows more columns than the publisher is fine (extra columns get defaults). A publisher that sends a column the subscriber does not have stops the apply worker. |
| Drop a column, drop a table | **Source first**, wait for lag = 0, then target | Otherwise the publisher still sends changes for something the subscriber already dropped. |
| Change a type, rename | Freeze. Do it before or after the migration. | Both orders break something. |

The repository has `scripts/12_ddl_during_migration.sh`, which adds a column (`beers.untappd_score`) and a table (`awards`) while replication runs, in the right order, and shows the one extra step new tables need:

```sql
-- on the target, after the DDL exists on both sides
SELECT aiven_extras.pg_alter_subscription_refresh_publication('sub_beerdb_from_pg15', TRUE);

-- did the new table join the party?
SELECT srrelid::regclass AS table_name, srsubstate
FROM pg_subscription_rel WHERE srrelid = 'awards'::regclass;
```

The column arrives on its own. The table does not: a `FOR ALL TABLES` publication includes it on the publisher immediately, but the subscriber only learns about it from a refresh, which also copies the rows that already exist. If you get the order wrong and write to a new column on the source before the target has it, the apply worker logs `logical replication target relation "public.beers" is missing replicated column`, `pg_stat_subscription_stats.apply_error_count` climbs, and the slot on the publisher starts hoarding WAL. The fix is to run the DDL on the target; the worker retries and picks up where it stopped. Nothing is lost, but nothing moves until you do.

The honest advice for most migrations: declare a DDL freeze for the hours it takes. It is cheaper than the choreography.

### Large objects: invisible to the publisher

PostgreSQL's large objects (`lo_create`, `lo_import`, the `oid` column that points at them) live in the system catalog `pg_largeobject`, and system catalogs are never part of a publication. The replication does not fail on them; it simply does not know they exist. Your `beers.label_lo` column replicates perfectly, with every oid pointing at a label that is not on the new server. The first `lo_get()` after cutover fails, and that is how most people find out.

Two checks tell you where you stand, and `scripts/07_verify_data.sh` runs both:

```sql
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

```bash
pg_dump "$SRC_URI" --format=custom --data-only --exclude-table='*' -b --file=large-objects.dump
pg_restore --dbname="$DST_URI" --data-only --no-owner --exit-on-error large-objects.dump
```

`pg_dump` preserves large object oids, so `beers.label_lo` points at the right label on the new server without any update. `scripts/11_copy_large_objects.sh` does this, then re-runs the hash on both sides, and `scripts/08_cutover.sh` calls it at the right moment, between "writes have stopped" and "sequences are synced". If you have many gigabytes of large objects, this is the step that defines your downtime, and it is a good argument for moving them to `bytea` or object storage before you migrate rather than after. If you have none, the script says so and leaves.

A third, smaller item in the same family: **sequences.** Identity columns and serials keep working on the target, but their sequences start where the empty target started. You sync them at cutover (step 8 below). PostgreSQL 19 replicates them natively.

## The demo: PostgreSQL 15 → 18 (or anywhere → Aiven) in a dozen scripts

The repository builds `beerdb`, a small craft-beer database: eight breweries with names only a DBA could love (WAL Street Brewery, Vacuum Full Brewing, Nullpointer Ales), sixteen beers from Kölsch 9.4 to Streaming Stout, five pubs, 30,000 tastings, a keg log with no primary key, a brew batch sequence, a stored generated column for the price per litre, and a label image per beer stored as a large object. A demo without the annoying parts teaches nothing.

### 1. Two services, one command each

```bash
avn service create --project $AVN_PROJECT --service-type pg --plan startup-4 \
  --cloud google-europe-west1 -c pg_version=15 pg-source-15
avn service create --project $AVN_PROJECT --service-type pg --plan startup-4 \
  --cloud google-europe-west1 -c pg_version=18 pg-target-18
avn service wait --project $AVN_PROJECT pg-source-15
avn service wait --project $AVN_PROJECT pg-target-18
```

`scripts/01_create_services.sh` does this, creates the `beerdb` database on both, and then checks what it created:

```sql
SELECT version();                           -- on both
SHOW wal_level;                             -- source: must be 'logical'
SHOW max_replication_slots;                 -- source: one per subscription
SHOW max_wal_senders;                       -- source: one per subscription
SHOW max_logical_replication_workers;       -- target: apply + sync workers
SHOW max_sync_workers_per_subscription;     -- target: parallel initial copy
```

The script refuses to continue if `wal_level` is anything but `logical`, which is exactly the check that saves you an hour when the source is RDS. **Migrating instead of upgrading?** Set `SOURCE_IS_AIVEN=false` and `SRC_URI=postgres://...` in `.env`; the script creates only the target and runs the same checks against your existing server.

### 2. Schema over, data stays

```bash
pg_dump "$SRC_URI" --schema-only --no-owner --no-privileges \
  --no-publications --no-subscriptions > schema-from-source.sql
psql "$DST_URI" -f schema-from-source.sql
```

`scripts/02_schema_and_seed.sh` seeds the source, dumps the schema with a `pg_dump` at least as new as the source server, and applies it on the target. `--no-owner --no-privileges` because role names rarely survive a change of provider (RDS has `rds_superuser`, Aiven has `avnadmin`); re-grant your application roles afterwards. Then the double check:

```sql
-- same statement on both sides, output diffed
SELECT n.nspname || '.' || c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema')
ORDER BY 1;
```

Same shape, no content. That is what we want before the copy.

### 3. Publish (and find the table without a primary key first)

`scripts/03_setup_publication.sh` starts with the preflight that finds `tap_log`:

```sql
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

It applies `ALTER TABLE tap_log REPLICA IDENTITY FULL` (in a real migration you would add a primary key instead; `FULL` writes the entire old row into WAL on every change and makes the subscriber scan for it), warns loudly about the sixteen large objects, and then publishes:

```sql
CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;
SELECT aiven_extras.pg_create_publication_for_all_tables(
  'pub_beerdb_all', 'INSERT,UPDATE,DELETE,TRUNCATE');

-- what is in it?
SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = 'pub_beerdb_all';
```

On a non-Aiven source the same script runs plain `CREATE PUBLICATION pub_beerdb_all FOR ALL TABLES`, which `rds_superuser`, `cloudsqlsuperuser` and `azure_pg_admin` are allowed to do.

### 4. Subscribe, then wait for every table to say "r"

```sql
CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;
SELECT aiven_extras.pg_create_subscription(
  'sub_beerdb_from_pg15',
  'host=pg-source-15-....aivencloud.com port=12345 dbname=beerdb user=avnadmin password=... sslmode=require',
  'pub_beerdb_all',
  'slot_beerdb_to_pg18',
  TRUE,   -- create the slot on the publisher
  TRUE);  -- copy_data: snapshot every table first, then stream
```

For a migration the connection string is simply your RDS, Cloud SQL or Azure endpoint. `scripts/04_setup_subscription.sh` builds it from `avn service get --json` (or takes `SRC_URI`), creates the subscription, and polls until every table is live:

```sql
-- pg_subscription is superuser-only; aiven_extras wraps it
SELECT subname, subenabled, subslotname, subpublications
FROM aiven_extras.pg_list_all_subscriptions();

-- i = initializing, d = copying data, f = copy finished, s = synchronized, r = ready and streaming
SELECT srrelid::regclass AS table_name, srsubstate, srsublsn
FROM pg_subscription_rel ORDER BY 1;
```

Only `r` means "live". The states are what you stare at during a large migration, because the initial copy is a plain `COPY` per table and a 500 GB table takes as long as a 500 GB `COPY` takes. `max_sync_workers_per_subscription` copies several tables in parallel.

### 5. Load, because a quiet database proves nothing

```bash
scripts/05_generate_load.sh 120 4
```

runs `pgbench` with a custom script: a guest rates a beer (insert into `tastings`), the beer's check-in counter goes up (update `beers`), an older tasting gets a better rating (update), the keg log gets a line (insert into the table without a primary key), and a brew batch number is consumed from the sequence. Four clients, two minutes. Run it in one terminal and keep the next script open in another.

### 6. Check from both ends

`scripts/06_check_replication.sh --watch` refreshes every five seconds and shows the things you will be asked about in a go/no-go meeting. On the publisher:

```sql
-- is the slot active, and how much WAL is it holding back?
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS wal_behind
FROM pg_replication_slots;

-- the walsender's view (Aiven: aiven_extras.pg_stat_replication_list(); elsewhere: pg_stat_replication)
SELECT application_name, state, sent_lsn, flush_lsn, replay_lsn, replay_lag
FROM pg_stat_replication;
```

On the subscriber:

```sql
-- how far behind is the apply worker?
SELECT subname, received_lsn, latest_end_lsn, now() - latest_end_time AS apply_delay
FROM pg_stat_subscription WHERE relid IS NULL;

-- anything failing? (PostgreSQL 18 adds the confl_* columns)
SELECT subname, apply_error_count, sync_error_count,
       confl_insert_exists, confl_update_missing, confl_delete_missing
FROM pg_stat_subscription_stats;
```

And the one number everyone wants, lag in bytes, which needs an LSN from each side:

```sql
-- publisher
SELECT pg_current_wal_lsn();
-- subscriber, with the value from above pasted in
SELECT pg_size_pretty(pg_wal_lsn_diff('0/1A2B3C4D', latest_end_lsn)) AS lag
FROM pg_stat_subscription WHERE relid IS NULL;
```

The slot query is the one to internalize. A replication slot makes the publisher keep every WAL segment the subscriber has not confirmed. If the subscriber goes away and the slot stays, `wal_behind` grows until the publisher's disk is full and the publisher stops accepting writes. That is the single most common way logical replication takes down a production database, and it is entirely self-inflicted. In a migration the publisher is your *current production system*, so this matters twice. `scripts/09_cleanup.sh` exists for this reason.

For live demos there is `--ping`: it inserts a marker row into `tap_log` on the source and times how long until it appears on the target. On two `startup-4` services in the same region that is typically well under a second, which tends to end the "is it real-time?" discussion.

### 7. Verify the content, not just the counts

`scripts/07_verify_data.sh` runs the same statement for every table on both sides and compares:

```sql
SELECT count(*), md5(string_agg(t::text, E'\n' ORDER BY t::text)) FROM tastings t;
```

Equal count and equal hash means equal content, including the `price_per_litre_cents` column that the PostgreSQL 18 side computed on its own. Then it prints every sequence on both sides, and finally the large object check from above, which at this point shows sixteen labels on the source and zero on the target, plus sixteen beers pointing at labels that do not exist yet. That gap is intentional; the cutover closes it.

Run the script while load is active and the table hashes differ, which is correct and a good moment to explain why. Run it after the load stops and they match.

### 8. Cutover: the fifteen seconds that matter

`scripts/08_cutover.sh` asks for confirmation and then does six things:

1. **Block writes on the source.** `ALTER DATABASE beerdb SET default_transaction_read_only = on`, then terminate existing application sessions, because the setting only applies to new ones. (On RDS or Cloud SQL you would do the same, or revoke `CONNECT` from the application role.)
2. **Drain.** Write one last marker row into `tap_log` and wait until it arrives on the target, then confirm zero lag (query below).
3. **Copy the large objects** with `scripts/11_copy_large_objects.sh`, now that nobody can change them, and compare the content hash on both sides.
4. **Sync sequences.** On the source, `pg_sequences` knows every `last_value`, identity columns included. The script turns that into `setval()` statements and runs them on the target (query below). Skip this and your first `INSERT` on the new server collides with an existing primary key. Everybody does this exactly once.
5. **ANALYZE.** A freshly loaded server has no planner statistics. One `ANALYZE` prevents the "the new version is slower" ticket that is really a "the planner is flying blind" ticket.
6. **Verify again** (step 7, now with matching large objects) and print the new connection string.

The two queries behind steps 2 and 4:

```sql
-- step 2, drain: publisher LSN vs. what the subscriber has applied (run one on each side)
SELECT pg_current_wal_lsn();                                              -- source
SELECT latest_end_lsn FROM pg_stat_subscription WHERE relid IS NULL;      -- target, must be >= the value above

-- step 4, sequences: run on the source, feed the output to the target
SELECT format('SELECT setval(%L, %s, true);',
              quote_ident(schemaname) || '.' || quote_ident(sequencename), last_value)
FROM pg_sequences
WHERE last_value IS NOT NULL AND schemaname NOT IN ('pg_catalog', 'information_schema');
```

Point your application at `pg-target-18`. Total write unavailability: from step 1 to the reconnect, usually seconds, plus however long step 3 takes if your labels are real PNGs.

The subscription stays until you decide you are done. If you want a real safety net, `scripts/10_reverse_replication.sh` creates a publication on the new PostgreSQL 18 server and a subscription on the old 15 with `copy_data = FALSE`. Every write that lands on 18 now also lands on 15. Rolling back means pointing the application back. Logical replication does not care that the publisher is newer than the subscriber, which is a sentence you cannot say about any other upgrade method. In a migration scenario this is the same trick in the other direction: the old RDS instance stays current until you cancel it.

### 9. Clean up, especially the slot

`scripts/09_cleanup.sh` drops the subscription (which drops the slot on the publisher), then checks that nothing was left behind:

```sql
-- on the publisher: this should not list your slot any more
SELECT slot_name, active, wal_status FROM pg_replication_slots;
```

With `TERMINATE=yes` it also removes both services. The check for orphaned slots is deliberately loud, and on a migration source you run it on the system you are about to decommission, which is exactly when people forget.

## Migrating to Aiven from RDS, Cloud SQL, Azure or anywhere: the same recipe

Nothing in the scripts is Aiven-specific on the source side except the `aiven_extras` call for the publication, and that has a plain-SQL branch. To migrate from somewhere else:

| Source | Turn on logical WAL | Who may create the publication |
|---|---|---|
| Amazon RDS / Aurora PostgreSQL | parameter group `rds.logical_replication = 1`, reboot | `rds_superuser` |
| Google Cloud SQL | flag `cloudsql.logical_decoding = on`, restart; `ALTER USER ... WITH REPLICATION` | `cloudsqlsuperuser` |
| Azure Database for PostgreSQL Flexible Server | server parameter `wal_level = logical`, restart; `ALTER ROLE ... WITH REPLICATION` | `azure_pg_admin` |
| Self-managed | `wal_level = logical`, `max_replication_slots`, `max_wal_senders`, `pg_hba.conf` entry | any superuser or role with `REPLICATION` |

Then: open the source firewall for the Aiven service (Aiven static IPs help if you must allow-list addresses), set `SOURCE_IS_AIVEN=false` and `SRC_URI` in `.env`, and run scripts 02 to 09 unchanged. The DDL freeze and the large object copy apply exactly as above; a migration source is more likely to have both, because it is older.

The version jump is free. A PostgreSQL 13 on RDS can publish to PostgreSQL 18 on Aiven in one go; there is no "upgrade in sequence" rule for logical replication the way there is for in-place upgrades. Extensions are the thing to check: every extension on the source needs to exist on the target version, and Aiven's extension list per version is public.



Or skip all of it and let Aiven's migration do the same thing:

```bash
avn service update --project $AVN_PROJECT \
  -c migration.host=mydb.abc123.eu-central-1.rds.amazonaws.com \
  -c migration.port=5432 -c migration.ssl=true \
  -c migration.username=postgres -c migration.password=... \
  -c migration.dbname=beerdb -c migration.method=replication \
  pg-target-18

avn service migration-status --project $AVN_PROJECT pg-target-18
```

The wizard uses logical replication for every database that meets the preconditions and falls back to `pg_dump` for the ones that do not. You now know what those preconditions are, and you know that it will not carry your large objects either.

## When the migration is big: scale, planning, and who helps

The demo is deliberately small. Sixteen beers and thirty thousand tastings replicate in seconds; a 2 TB database with 400 tables, or sixty databases spread across three teams, do not. The procedure is the same for both: schema first, publication, subscription, drain, cutover. What grows with size is everything around the procedure. An inventory of databases, extensions, roles, large objects and tables without primary keys. A sequence that decides which workloads move first and which share a cutover window. Rehearsals against forks or restored backups until the runbook is boring. Explicit rollback criteria, and a person who owns the go decision. Capacity for the initial copy, which takes as long as a `COPY` of your largest table takes, and for the WAL the source retains while it runs. A large migration is a project with a plan, test runs and a strategy for the order of things, and the SQL in this post is the part of that project that does not get harder. For the part that does, Aiven's teams have done this many times: in-house expertise for the assessment and the plan, and a partner network for implementations that need more hands than a blog post provides. The right moment to talk is before the first replication slot exists, not after the first disk is full.

## What PostgreSQL 18 changed for logical replication

PostgreSQL 18 (released 25 September 2025; Aiven runs 18.6 and uses 18 as the default for new services) is a quality-of-life release for replication:

- **Generated columns are published.** `publish_generated_columns` on the publication, or a column list that names them. Before 18 the subscriber had to compute generated columns itself, which works between PostgreSQL servers and fails for everything else. In our 15 → 18 demo the publisher is still 15, so the subscriber computes `price_per_litre_cents`. With an 18 publisher you can choose.
- **Conflicts are logged and counted.** `insert_exists`, `update_origin_differs`, `update_exists`, `update_missing`, `delete_origin_differs`, `delete_missing`, `multiple_unique_conflicts`: each gets a log line with the conflicting key and a counter in `pg_stat_subscription_stats`. Diagnosing a stuck subscription went from "read the logs and guess" to "read one row".
- **`streaming = parallel` is the default** for new subscriptions. Large in-progress transactions are applied by parallel workers instead of being spooled to disk first.
- **`ALTER SUBSCRIPTION ... SET (two_phase = ...)`** works on an existing subscription.
- **`idle_replication_slot_timeout`** invalidates slots nobody has consumed for a while. This is the server-side answer to the disk-full story above. Aiven's own slot handling already protects you from the worst of it; this GUC makes the protection standard PostgreSQL.
- **`max_active_replication_origins`** is its own setting, so many subscriptions no longer force a high `max_replication_slots`.
- **`pg_createsubscriber`** gained `--all`, `--clean` and `--enable-two-phase`. It converts a physical standby into a logical subscriber in one step, which is the fastest way to bootstrap a huge logical replica. It needs file-system access to the standby, so it is a self-managed tool; on Aiven the `copy_data` snapshot does the same job over the network.

## What PostgreSQL 19 brings (beta 4, 24 September 2026)

PostgreSQL 19 is in beta at the time of writing, so treat the list as "in the beta 4 release notes", not "in your production server next week". The logical replication section is the longest it has been in years:

- **Sequences replicate.** `CREATE PUBLICATION ... FOR ALL SEQUENCES`, and `ALTER SUBSCRIPTION ... REFRESH SEQUENCES` syncs their values; `pg_get_sequence_data()` lets you inspect the state. Step 4 of our cutover becomes a one-liner, and the most common post-cutover incident disappears.
- **`ALL TABLES EXCEPT (...)`** on publications. Finally a way to say "everything but the 400 GB event archive".
- **`retain_dead_tuples`** on subscriptions keeps the information needed to detect `update_deleted` conflicts (an update arriving for a row that was concurrently deleted), with `max_retention_duration` as the safety valve, and a new `update_deleted` counter in `pg_stat_subscription_stats`.
- **Automatic logical WAL level.** With `wal_level = replica`, the server switches to logical decoding when a logical slot needs it, without a restart. `effective_wal_level` reports what is actually in effect. Self-managed sources no longer need the restart that RDS, Cloud SQL and Azure still require today.
- **`CREATE SUBSCRIPTION ... SERVER`** takes its connection details from a `postgres_fdw` foreign server, so passwords stop living in subscription definitions.
- **Per-subscription `wal_receiver_timeout`**, so a slow cross-region link (hello, migration from another continent) does not force a global setting.
- **`REPACK CONCURRENTLY`**, the successor of `VACUUM FULL` and `CLUSTER`, rebuilds a table without an exclusive lock and uses logical decoding internally to replay changes made during the rebuild. Not replication as such, but the same machinery, and a hint at how central logical decoding has become.

Still not on the list: DDL replication and large objects. Plan for both the way this post does.

## The two-minute version for your next architecture call

- Streaming replication copies a cluster; logical replication moves a database. Different tools for different jobs.
- A major version upgrade and a migration to Aiven are the same procedure. Only the source hostname changes.
- The cost is an application reconnect, not a maintenance window, and the old server stays intact as a rollback, optionally kept in sync.
- Logical replication carries table rows. It does not carry DDL (freeze it, or target-first for additive changes), large objects (`pg_dump -b` at cutover), or sequences before PostgreSQL 19 (`setval()` at cutover).
- On Aiven: `wal_level` is already `logical`, `aiven_extras` replaces superuser, and `avn service update -c migration.*` wraps the whole procedure when the standard case fits. The scripts in the repository are for when it does not.
- Three things to check before any migration: replica identities, large objects, extensions on the target version. One thing to check after: no orphaned slot on the source.
- PostgreSQL 18 made conflicts visible; PostgreSQL 19 makes sequences replicate. Both make the method easier, neither changes it.

Clone [the repository](https://github.com/dkrautschick/postgresql-logicalreplication-upgrade), set `AVN_PROJECT`, and run the scripts in order. An afternoon and two `startup-4` services later you will have upgraded a database without anyone noticing, with every beer label where it belongs. Which is, after all, the whole point.
