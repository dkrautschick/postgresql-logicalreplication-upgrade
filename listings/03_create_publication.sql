-- Step 3. Run on the SOURCE.

-- Aiven source (no superuser): aiven_extras runs CREATE PUBLICATION FOR ALL TABLES for you
CREATE EXTENSION IF NOT EXISTS aiven_extras CASCADE;
SELECT * FROM aiven_extras.pg_create_publication_for_all_tables('pub_beerdb_all', 'INSERT,UPDATE,DELETE,TRUNCATE');

-- Non-Aiven source (rds_superuser, cloudsqlsuperuser, azure_pg_admin, or a real superuser):
-- CREATE PUBLICATION pub_beerdb_all FOR ALL TABLES WITH (publish = 'insert,update,delete,truncate');

-- Double check
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate FROM pg_publication;
SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = 'pub_beerdb_all' ORDER BY 1, 2;
