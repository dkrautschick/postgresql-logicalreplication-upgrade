-- Step 10 (optional rollback path): replicate from the NEW major back to the OLD one after cutover.
-- Prerequisite: the forward subscription has been dropped (09_cleanup.sql) and no application writes to the old server.

-- On the TARGET (now the primary):
CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;
SELECT * FROM aiven_extras.pg_create_publication_for_all_tables('pub_beerdb_reverse', 'INSERT,UPDATE,DELETE,TRUNCATE');

-- On the SOURCE (old server). The apply worker is a normal session, so the read-only default must go.
ALTER DATABASE beerdb RESET default_transaction_read_only;
CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;
SELECT * FROM aiven_extras.pg_create_subscription(
  'sub_beerdb_from_pg18',
  'host=<DST_HOST> port=<DST_PORT> dbname=beerdb user=<DST_USER> password=<DST_PASSWORD> sslmode=require',
  'pub_beerdb_reverse',
  'slot_beerdb_to_pg15',
  TRUE,
  FALSE      -- copy_data = FALSE: both sides are identical at this moment
);
SELECT subname, subenabled, subslotname FROM aiven_extras.pg_list_all_subscriptions();
