-- Bad: the schema an agent writes from habit. Every column is nullable,
-- keys are serial or random UUIDs, and the types come from other databases.
-- The assertions describe what goes wrong.
CREATE EXTENSION pgstattuple;

-- MISTAKE: serial is a 4-byte integer with a separate sequence; it runs out at 2147483647
-- and does not notice ids written by hand.
CREATE TABLE customers (
  id serial PRIMARY KEY,
  -- MISTAKE: varchar(20) is a guess at a business rule; it still accepts '' and casts truncate silently.
  email varchar(20),
  -- MISTAKE: timestamp without time zone stores wall-clock time and drops the offset.
  created_at timestamp DEFAULT now()
);

CREATE TABLE orders (
  -- MISTAKE: random UUIDv4 keys land on random leaf pages and split them half full.
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- MISTAKE: no REFERENCES and no NOT NULL; orphans and missing values get in.
  customer_id integer,
  status varchar(10),
  -- MISTAKE: double precision cannot represent 0.10 exactly.
  total double precision,
  placed_at timestamp,
  -- MISTAKE: json keeps duplicate keys, reparses on every read and has no = operator.
  details json
);

-- A data import writes ids by hand; the sequence still starts at 1.
INSERT INTO customers (id, email) VALUES (1, 'ana@example.com'), (2, 'bruno@example.com');
SELECT assert_error($$INSERT INTO customers (email) VALUES ('carla@example.com')$$, '23505',
  'serial hands out id 1 again after a manual insert: duplicate key');

-- The integer key runs out at 2^31 - 1.
SELECT setval('customers_id_seq', 2147483647);
SELECT assert_error($$INSERT INTO customers (email) VALUES ('dan@example.com')$$, '2200H',
  'the serial sequence stops at 2147483647 and inserts fail');

-- varchar(n) accepts an empty email, and an explicit cast truncates without an error.
INSERT INTO customers (id, email) VALUES (3, '');
INSERT INTO customers (id, email) VALUES (4, 'a.very.long.address@example.com'::varchar(20));
SELECT assert_true((SELECT email FROM customers WHERE id = 4) = 'a.very.long.address@',
  'the cast silently cut the email to 20 characters');
SELECT assert_true((SELECT count(*) FROM customers WHERE email = '') = 1,
  'varchar(20) stored an empty email');

-- Shrinking a varchar limit rewrites the whole table under ACCESS EXCLUSIVE.
UPDATE customers SET email = left(email, 10);
CREATE TEMP TABLE before AS SELECT pg_relation_filenode('customers') AS node;
ALTER TABLE customers ALTER COLUMN email TYPE varchar(10);
SELECT assert_true(pg_relation_filenode('customers') <> (SELECT node FROM before),
  'changing varchar(20) to varchar(10) wrote a new copy of the table');

-- Two writers in different time zones record the same instant as two values.
SET TIME ZONE 'America/Sao_Paulo';
INSERT INTO orders (customer_id, status, total, placed_at) VALUES (1, 'paid', 0.10, '2026-03-01 09:00:00-03');
SET TIME ZONE 'Asia/Tokyo';
INSERT INTO orders (customer_id, status, total, placed_at) VALUES (1, 'paid', 0.10, '2026-03-01 21:00:00+09');
SET TIME ZONE 'UTC';
SELECT assert_true((SELECT max(placed_at) - min(placed_at) FROM orders) = interval '12 hours',
  'timestamp ignored both offsets: the same instant is stored 12 hours apart');

-- Ten orders of 0.10 do not add up to 1.
INSERT INTO orders (customer_id, status, total, placed_at)
SELECT 2, 'paid', 0.10, now() FROM generate_series(1, 8);
SELECT assert_true((SELECT sum(total) FROM orders) <> 1,
  'double precision sums 10 x 0.10 to 0.9999999999999999');

-- Nullable columns and no FK: the database accepts rows the application cannot use.
INSERT INTO orders (customer_id, status, total, placed_at) VALUES (999, NULL, NULL, NULL);
SELECT assert_true((SELECT count(*) FROM orders WHERE total >= 0) + (SELECT count(*) FROM orders WHERE total < 0)
  < (SELECT count(*) FROM orders),
  'a NULL total is neither >= 0 nor < 0, so it drops out of both reports');
SELECT assert_true((SELECT count(*) FROM orders o WHERE NOT EXISTS (SELECT 1 FROM customers c WHERE c.id = o.customer_id)) = 1,
  'an order for customer 999, who does not exist, was stored');

-- json accepts anything shaped like JSON, keeps duplicates and cannot be compared.
UPDATE orders SET details = '{"gift": true, "gift": false, "total": "abc"}' WHERE customer_id = 999;
SELECT assert_true((SELECT details::text FROM orders WHERE customer_id = 999) LIKE '%"gift": true, "gift": false%',
  'json stored both copies of the duplicate key and a non-numeric total');
SELECT assert_error($$SELECT 1 FROM orders WHERE details = '{}'::json$$, '42883',
  'json has no equality operator');

-- Random keys: the same 200000 UUIDs, inserted in random order vs in key order.
CREATE TABLE random_keys (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
INSERT INTO random_keys SELECT FROM generate_series(1, 200000);
CREATE TABLE ordered_keys (id uuid PRIMARY KEY);
INSERT INTO ordered_keys SELECT id FROM random_keys ORDER BY id;
SELECT assert_true((SELECT avg_leaf_density FROM pgstatindex('random_keys_pkey')) < 75,
  'random inserts leave leaf pages about 65% full after splits');
SELECT assert_true(pg_relation_size('random_keys_pkey') > 1.3 * pg_relation_size('ordered_keys_pkey'),
  'the index built from random-order inserts is over 30% larger for the same keys');
