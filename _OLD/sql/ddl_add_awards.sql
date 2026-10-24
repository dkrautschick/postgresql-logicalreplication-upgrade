-- Example of DDL during an active migration: a new column and a new table.
-- Apply on the TARGET first, then on the SOURCE, then refresh the subscription (12_ddl_during_migration.sh).
ALTER TABLE beers ADD COLUMN IF NOT EXISTS untappd_score numeric(3,2);

CREATE TABLE IF NOT EXISTS awards (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    beer_id  bigint NOT NULL REFERENCES beers(id),
    award    text NOT NULL,
    year     integer NOT NULL
);
