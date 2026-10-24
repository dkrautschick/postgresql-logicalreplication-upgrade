-- Demo schema: a small craft-beer taproom. It deliberately contains everything that bites people
-- during logical replication: identity columns (sequences), a stored generated column, foreign keys,
-- a table without a primary key, a standalone sequence, and large objects (beer label images).

CREATE TABLE breweries (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        text NOT NULL UNIQUE,
    city        text NOT NULL,
    country     text NOT NULL,
    founded     integer
);

CREATE TABLE beers (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    brewery_id  bigint NOT NULL REFERENCES breweries(id),
    name        text NOT NULL,
    style       text NOT NULL,
    abv         numeric(4,1) NOT NULL CHECK (abv >= 0 AND abv < 70),
    ibu         integer,
    checkins    integer NOT NULL DEFAULT 0,
    label_lo    oid,               -- large object with the label image: NOT replicated, see 11_copy_large_objects.sh
    UNIQUE (brewery_id, name)
);

CREATE TABLE pubs (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        text NOT NULL,
    city        text NOT NULL,
    taps        integer NOT NULL CHECK (taps > 0)
);

CREATE TABLE tastings (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    beer_id     bigint NOT NULL REFERENCES beers(id),
    pub_id      bigint NOT NULL REFERENCES pubs(id),
    rating      smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
    pour_ml     integer NOT NULL CHECK (pour_ml > 0),
    price_cents integer NOT NULL CHECK (price_cents >= 0),
    -- STORED generated column. A PostgreSQL 15 publisher does not send it; the PostgreSQL 18 subscriber
    -- recomputes it. From 18 on, a publisher can send it (publish_generated_columns).
    price_per_litre_cents integer GENERATED ALWAYS AS ((price_cents * 1000) / pour_ml) STORED,
    tasted_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX tastings_beer_idx ON tastings (beer_id);

-- No primary key on purpose. INSERTs replicate fine, UPDATE/DELETE need a replica identity.
CREATE TABLE tap_log (
    logged_at   timestamptz NOT NULL DEFAULT now(),
    note        text NOT NULL
);

-- A standalone sequence (brew batch numbers): logical replication ignores it until PostgreSQL 19.
CREATE SEQUENCE batch_number_seq START WITH 2026001;
