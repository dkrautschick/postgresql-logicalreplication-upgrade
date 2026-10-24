-- Step 4. Run on the TARGET.
CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;

-- args: subscription name, conninfo to the PUBLISHER, publication, slot name, create slot?, copy existing data?
SELECT * FROM aiven_extras.pg_create_subscription(
  'sub_beerdb_from_pg15',
  'host=<SRC_HOST> port=<SRC_PORT> dbname=beerdb user=<SRC_USER> password=<SRC_PASSWORD> sslmode=require',
  'pub_beerdb_all',
  'slot_beerdb_to_pg18',
  TRUE,
  TRUE
);

-- pg_subscription is superuser-only on Aiven; the wrapper shows it
SELECT subname, subenabled, subslotname, subpublications FROM aiven_extras.pg_list_all_subscriptions();
