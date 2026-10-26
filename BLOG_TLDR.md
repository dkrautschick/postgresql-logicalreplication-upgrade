# TL;DR: Two elephants, one WAL

> Upgrade PostgreSQL® 15 to 18, or migrate from RDS, Cloud SQL or Azure to Aiven, with **seconds of downtime** instead of a maintenance window. Both jobs use the same logical replication procedure. Only the source hostname changes.

## Why now

PostgreSQL 14 reaches end of life on **12 November 2026**, and 15 follows in **November 2027**. After end of life Aiven can no longer support that version, and the upgrade falls to you.

## Why not just `pg_upgrade`?

| | `pg_upgrade` | Logical replication |
|---|---|---|
| Downtime | Database unavailable while it runs | Seconds to drain and reconnect |
| Rollback | Restore a backup or fork | Old server stays intact, optionally kept in sync |
| Works across providers | No | **Yes** |

## What logical replication will not carry

| Not replicated | What you do |
|---|---|
| **DDL** | Freeze schema changes during the migration, or apply them target first for additive changes |
| **Large objects** | Copy them at cutover with `pg_dump -b` |
| **Sequences** (before PostgreSQL 19) | Sync them at cutover with `setval()` |

## The procedure

1. Create the source and target services
2. Copy the schema
3. Publish on the source
4. Subscribe on the target and wait for every table to reach `r`
5. Generate load
6. Check lag and slots from both ends
7. Verify content with counts and hashes
8. Cut over: block writes, drain, copy large objects, sync sequences, `ANALYZE`, verify
9. Clean up, especially the replication slot

Every step has a numbered script in the [companion repository](https://github.com/dkrautschick/postgresql-logicalreplication-upgrade).

## Watch out for

- **Orphaned slots.** A replication slot keeps every WAL segment until you drop it, which can fill a production disk.
- **Tables without a primary key.** Give them one, or set `REPLICA IDENTITY FULL` and accept the cost.
- **Extensions.** Every extension on the source needs to exist on the target version.

## The shortcut

If your source meets the preconditions, one command does the same job:

```
avn service update -c migration.*
```

The scripts are for when it does not.

## What's next in PostgreSQL

- **PostgreSQL 18:** conflicts are logged and counted, and `streaming = parallel` is the default.
- **PostgreSQL 19 (beta):** sequence replication, `ALL TABLES EXCEPT`, and automatic logical WAL level.

---

**Next step:** clone the repository and run script 01.
