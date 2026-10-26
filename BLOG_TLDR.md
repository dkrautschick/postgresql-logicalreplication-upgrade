# TL;DR: Move the elephant, keep the lights on

- **The goal:** Upgrade PostgreSQL® to a new major version (from 10 or newer), or migrate from RDS, Cloud SQL, Azure or a self-managed server to Aiven, with seconds of downtime and the old server as a rollback. It is the same procedure for both, and only the source changes.
- **Why logical replication:** `pg_upgrade` is fast but blocks the database while it runs and is one-way. Logical replication lets you rehearse, cut over in seconds and roll back. If your source qualifies, `avn service update -c migration.*` ([aiven-db-migrate](https://aiven.io/docs/products/postgresql/howto/migrate-aiven-db-migrate)) does it in one command.
- **What it won't carry:** DDL (freeze it), large objects (`pg_dump -b` at cutover) and sequences (`setval()` before PostgreSQL 19).
- **The procedure:** Nine scripted steps from schema copy to cutover, verified with counts and hashes. Drop the replication slot afterwards, or an orphaned slot keeps WAL until it fills your disk.
- **What's next:** PostgreSQL 18 makes conflicts visible, PostgreSQL 19 (release candidate 1, general availability planned for 19 November 2026) replicates sequences, and extensions get their own follow-up post.
