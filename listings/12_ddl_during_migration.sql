-- Step 12 (optional): additive DDL while replication runs. Order: TARGET first, SOURCE second, then refresh.

-- 1. On the TARGET
ALTER TABLE beers ADD COLUMN IF NOT EXISTS untappd_score numeric(3,2);
CREATE TABLE IF NOT EXISTS awards (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    beer_id bigint NOT NULL REFERENCES beers(id),
    award text NOT NULL,
    year integer NOT NULL
);

-- 2. On the SOURCE (same DDL), then write to it
ALTER TABLE beers ADD COLUMN IF NOT EXISTS untappd_score numeric(3,2);
CREATE TABLE IF NOT EXISTS awards (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    beer_id bigint NOT NULL REFERENCES beers(id),
    award text NOT NULL,
    year integer NOT NULL
);
UPDATE beers SET untappd_score = round((3 + random() * 1.8)::numeric, 2);
INSERT INTO awards (beer_id, award, year) VALUES (5, 'Gold, European Beer Star', 2025);

-- 3. On the TARGET: the column change arrives on its own; the new TABLE needs a refresh
SELECT count(untappd_score) FROM beers;                                   -- > 0 within seconds
SELECT count(*) FROM pg_subscription_rel WHERE srrelid = 'awards'::regclass;  -- 0 until refreshed
SELECT * FROM aiven_extras.pg_alter_subscription_refresh_publication('sub_beerdb_from_pg15', TRUE);
SELECT srrelid::regclass, srsubstate FROM pg_subscription_rel WHERE srrelid = 'awards'::regclass;  -- wait for 'r'

-- Wrong order (source first, then write) stops the apply worker:
-- "logical replication target relation "public.beers" is missing replicated column". Fix: run the DDL on the target.
-- Destructive DDL (DROP, type change, rename): source first, wait for lag = 0, then target. Or freeze DDL.
