-- Seed data: real-ish beers, generated tastings. Small enough to copy in seconds.
INSERT INTO breweries (name, city, country, founded) VALUES
  ('Brauerei Zum Dicken Elefanten', 'Stolberg', 'DE', 1868),
  ('Schnurrbart Brewing', 'Aachen', 'DE', 2016),
  ('Hop Hop Array', 'Helsinki', 'FI', 2014),
  ('WAL Street Brewery', 'Berlin', 'DE', 2019),
  ('Lager Lager Lager', 'Köln', 'DE', 1986),
  ('Nullpointer Ales', 'Dublin', 'IE', 2012),
  ('Vacuum Full Brewing', 'Porto', 'PT', 2020),
  ('Shared Buffers Craft', 'Austin', 'US', 2011);

INSERT INTO beers (brewery_id, name, style, abv, ibu) VALUES
  (1, 'Elefanten Export', 'Export', 5.4, 22),
  (1, 'Rüssel Rauchbier', 'Rauchbier', 5.8, 28),
  (2, 'Handlebar Hazy', 'Hazy IPA', 6.5, 45),
  (2, 'Twirl Tripel', 'Tripel', 8.7, 30),
  (3, 'Index Scan IPA', 'West Coast IPA', 6.8, 70),
  (3, 'Sequential Sahti', 'Sahti', 7.5, 12),
  (4, 'Logical Lager', 'Helles', 4.9, 18),
  (4, 'Streaming Stout', 'Imperial Stout', 10.2, 60),
  (4, 'Replica Identity Red', 'Red Ale', 5.6, 35),
  (5, 'Kölsch 9.4', 'Kölsch', 4.8, 20),
  (6, 'Segfault Session', 'Session IPA', 4.2, 40),
  (6, 'Null Porter', 'Porter', 5.9, 32),
  (7, 'Bloat Bock', 'Doppelbock', 8.1, 25),
  (7, 'Autovacuum Weizen', 'Hefeweizen', 5.3, 14),
  (8, 'Checkpoint Pilsner', 'Pilsner', 5.0, 38),
  (8, 'WAL Segment Saison', 'Saison', 6.4, 27);

INSERT INTO pubs (name, city, taps) VALUES
  ('The Idle Slot', 'Stolberg', 12),
  ('Pub & Sub', 'Aachen', 8),
  ('Olutravintola Toast', 'Helsinki', 20),
  ('Zum Primary Key', 'Berlin', 16),
  ('Zero Downtime Bar', 'Köln', 10);

-- 30,000 tastings spread over the last year
INSERT INTO tastings (beer_id, pub_id, rating, pour_ml, price_cents, tasted_at)
SELECT (random() * 15)::int + 1,
       (random() * 4)::int + 1,
       (random() * 4)::int + 1,
       (ARRAY[200, 300, 330, 400, 500])[(random() * 4)::int + 1],
       (random() * 400)::int + 350,
       now() - (random() * interval '365 days')
FROM generate_series(1, 30000);

UPDATE beers b SET checkins = t.n
FROM (SELECT beer_id, count(*) AS n FROM tastings GROUP BY beer_id) t WHERE t.beer_id = b.id;

INSERT INTO tap_log (note)
SELECT format('keg changed: %s', name) FROM beers;

SELECT nextval('batch_number_seq') FROM generate_series(1, 42);

-- Label "images" as large objects. Real labels would be PNGs; a few hundred random bytes are enough
-- to prove the point: large objects live outside the table and logical replication skips them.
UPDATE beers SET label_lo = lo_from_bytea(0, decode(md5(name) || md5(style) || md5(abv::text), 'hex'));
