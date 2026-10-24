# Sources outside Aiven: what to switch on before step 3

The scripts and listings do not change; only the source needs logical WAL and a role that may publish.

| Source | Turn on logical WAL | Publication role |
|---|---|---|
| Amazon RDS / Aurora PostgreSQL | parameter group `rds.logical_replication = 1`, reboot | `rds_superuser` |
| Google Cloud SQL | flag `cloudsql.logical_decoding = on`, restart; `ALTER USER <user> WITH REPLICATION` | `cloudsqlsuperuser` |
| Azure Database for PostgreSQL Flexible Server | server parameter `wal_level = logical`, restart; `ALTER ROLE <user> WITH REPLICATION` | `azure_pg_admin` |
| Self-managed | `wal_level = logical`, `max_replication_slots`, `max_wal_senders`, `pg_hba.conf` entry for the Aiven service, restart | superuser or `REPLICATION` role |

Then:

```sql
-- on the source
SHOW wal_level;                                   -- 'logical'
CREATE PUBLICATION pub_beerdb_all FOR ALL TABLES WITH (publish = 'insert,update,delete,truncate');
```

```bash
# network: the Aiven subscriber connects TO the source; its firewall / security group must allow the Aiven service.
# Aiven static IP addresses give you stable addresses to allow-list.
# .env for the scripts:
SOURCE_IS_AIVEN=false
SRC_URI=postgres://<user>:<password>@<host>:5432/beerdb?sslmode=require
```

Everything from step 2 on is identical. A PostgreSQL 13 source can publish straight to PostgreSQL 18;
there is no version-by-version rule. Check extensions: every extension on the source must exist on the
target version (Aiven publishes the list per version).
