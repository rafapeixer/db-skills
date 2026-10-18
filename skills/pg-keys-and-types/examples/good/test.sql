-- Good: bigint identity keys (or uuidv7 on PG 18+), timestamptz, text with
-- CHECK, numeric money, NOT NULL by default, CHECK and FK constraints, and
-- jsonb only for the attributes that really have no fixed shape.
CREATE EXTENSION pgstattuple;

CREATE TABLE customers (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customers_email_len CHECK (char_length(email) BETWEEN 3 AND 254)
);

CREATE TABLE orders (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers (id),
  status text NOT NULL CHECK (status IN ('pending', 'paid', 'shipped')),
  total numeric(12, 2) NOT NULL CHECK (total >= 0),
  placed_at timestamptz NOT NULL,
  attributes jsonb NOT NULL DEFAULT '{}'
);
-- Declaring the FK does not create this index; deletes on customers need it.
CREATE INDEX orders_customer_id_idx ON orders (customer_id);

INSERT INTO customers (email) VALUES ('ana@example.com'), ('bruno@example.com');

-- Rule 1: GENERATED ALWAYS rejects a hand-written id (generated_always).
SELECT assert_error($$INSERT INTO customers (id, email) VALUES (1, 'x@example.com')$$, '428C9',
  'GENERATED ALWAYS refuses an explicit id without OVERRIDING SYSTEM VALUE');

-- Rule 3: two writers in different time zones record the same instant.
SET TIME ZONE 'America/Sao_Paulo';
INSERT INTO orders (customer_id, status, total, placed_at) VALUES (1, 'paid', 0.10, '2026-03-01 09:00');
SET TIME ZONE 'Asia/Tokyo';
INSERT INTO orders (customer_id, status, total, placed_at) VALUES (1, 'paid', 0.10, '2026-03-01 21:00');
SET TIME ZONE 'UTC';
SELECT assert_true((SELECT count(DISTINCT placed_at) FROM orders) = 1,
  'timestamptz stores one instant for 09:00 in Sao Paulo and 21:00 in Tokyo');
SELECT assert_true((SELECT min(placed_at) FROM orders) = '2026-03-01 12:00:00+00',
  'the stored instant is 12:00 UTC whatever the writer''s TimeZone was');

-- Rule 5: ten orders of 0.10 add up to exactly 1.00.
INSERT INTO orders (customer_id, status, total, placed_at)
SELECT 2, 'paid', 0.10, now() FROM generate_series(1, 8);
SELECT assert_true((SELECT sum(total) FROM orders) = 1.00,
  'numeric sums money exactly: 10 x 0.10 = 1.00');

-- Rules 4 and 6: every invalid row is refused by the database.
SELECT assert_error($$INSERT INTO orders (customer_id, status, total, placed_at) VALUES (1, 'paid', NULL, now())$$, '23502',
  'NOT NULL refuses an order without a total');
SELECT assert_error($$INSERT INTO orders (customer_id, status, total, placed_at) VALUES (1, 'paid', -5, now())$$, '23514',
  'CHECK refuses a negative total');
SELECT assert_error($$INSERT INTO orders (customer_id, status, total, placed_at) VALUES (1, 'payed', 5, now())$$, '23514',
  'CHECK refuses a misspelled status');
SELECT assert_error($$INSERT INTO orders (customer_id, status, total, placed_at) VALUES (999, 'paid', 5, now())$$, '23503',
  'the foreign key refuses an order for a customer that does not exist');
SELECT assert_error($$INSERT INTO customers (email) VALUES ('')$$, '23514',
  'the length CHECK refuses an empty email, which varchar(n) would accept');
SELECT assert_error($$INSERT INTO customers (email) VALUES (repeat('a', 300))$$, '23514',
  'the length CHECK refuses an email over 254 characters');

-- Rule 4: changing the limit is a constraint swap, not a table rewrite.
CREATE TEMP TABLE before AS SELECT pg_relation_filenode('customers') AS node;
ALTER TABLE customers DROP CONSTRAINT customers_email_len,
  ADD CONSTRAINT customers_email_len CHECK (char_length(email) BETWEEN 3 AND 320) NOT VALID;
ALTER TABLE customers VALIDATE CONSTRAINT customers_email_len;
SELECT assert_true(pg_relation_filenode('customers') = (SELECT node FROM before),
  'raising a CHECK length limit keeps the same file: no rewrite');

-- Rule 7: jsonb for the schemaless part; typed columns for what you query.
UPDATE orders SET attributes = '{"gift": true, "gift": false, "note": "ring twice"}' WHERE id = 1;
SELECT assert_true((SELECT attributes FROM orders WHERE id = 1) = '{"note": "ring twice", "gift": false}',
  'jsonb keeps the last duplicate key and compares documents with =');
SELECT assert_error($$INSERT INTO orders (customer_id, status, total, placed_at) VALUES (1, 'paid', 'abc', now())$$, '22P02',
  'a typed column refuses a total that is not a number');

-- Rule 6: the referencing column leads an index of its own.
SELECT assert_true(EXISTS (
  SELECT 1 FROM pg_index i
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
  WHERE i.indrelid = 'orders'::regclass AND a.attname = 'customer_id'),
  'orders.customer_id is indexed, so deleting a customer does not scan orders');

-- Rules 1 and 2: ordered keys grow the index at its right edge, so leaf
-- pages stay at the 90% fillfactor instead of being split half full.
CREATE TABLE events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  happened_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO events (happened_at) SELECT now() FROM generate_series(1, 200000);
SELECT assert_true((SELECT avg_leaf_density FROM pgstatindex('events_pkey')) >= 85,
  'bigint identity keys fill leaf pages to about 90%');

DO $$
DECLARE
  density float8;
BEGIN
  IF current_setting('server_version_num')::int < 180000 THEN
    RAISE NOTICE 'uuidv7() needs PG 18+; generate UUIDv7 in the application on older versions';
    RETURN;
  END IF;
  -- PG 18+: a time-ordered UUID key behaves like bigint identity.
  EXECUTE 'CREATE TABLE devices (id uuid PRIMARY KEY DEFAULT uuidv7(), name text NOT NULL)';
  EXECUTE 'INSERT INTO devices (name) SELECT ''d'' || g FROM generate_series(1, 200000) g';
  SELECT avg_leaf_density INTO density FROM pgstatindex('devices_pkey');
  PERFORM assert_true(density >= 85, format('uuidv7 keys fill leaf pages to about 90%% (got %s)', density));
END
$$;
