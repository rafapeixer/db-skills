-- Bad: OFFSET pagination, a query per row, row-by-row inserts and SELECT *.
-- The assertions describe the bad outcome, so this file fails if a mistake
-- stops costing what the skill says it costs.

CREATE TABLE orders (
    id          bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    total_cents bigint NOT NULL,
    note        text,
    created_at  timestamptz NOT NULL
);
CREATE INDEX orders_customer_created_id ON orders (customer_id, created_at, id);

CREATE TABLE order_items (
    order_id bigint NOT NULL REFERENCES orders (id),
    sku      text NOT NULL,
    qty      int NOT NULL,
    PRIMARY KEY (order_id, sku)
);

-- 100,000 orders for 10 customers: 10,000 orders per customer.
INSERT INTO orders (id, customer_id, total_cents, created_at)
SELECT g, g % 10 + 1, g * 7 % 10000, timestamptz '2026-01-01 00:00:00+00' + g * interval '1 minute'
FROM generate_series(1, 100000) AS g;

INSERT INTO order_items (order_id, sku, qty)
SELECT o, 'sku-' || n, (o + n) % 5 + 1
FROM generate_series(1, 100000) AS o, generate_series(1, 3) AS n;

VACUUM ANALYZE orders;
VACUUM ANALYZE order_items;

CREATE FUNCTION scanned_rows(query text, rel text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  plan jsonb;
BEGIN
  EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON, COSTS OFF, TIMING OFF) ' || query INTO plan;
  RETURN (SELECT sum((n ->> 'Actual Rows')::numeric * (n ->> 'Actual Loops')::numeric)::bigint
          FROM jsonb_path_query(plan, 'strict $.** ? (@."Relation Name" == $r)', jsonb_build_object('r', rel)) AS n);
END
$$;

-- Count statements run inside DO blocks too, so the loops below show up.
SET pg_stat_statements.track = 'all';

-- 1. OFFSET pagination.
-- MISTAKE: OFFSET reads and throws away every earlier row. The last page of
-- this customer reads 10,000 index entries to return 20; cost grows with depth.
SELECT assert_true(
    scanned_rows($q$SELECT id, created_at FROM orders WHERE customer_id = 3
                    ORDER BY created_at DESC, id DESC LIMIT 20 OFFSET 9980$q$, 'orders') = 10000,
    'the deep OFFSET page reads 10,000 rows to return 20');

-- MISTAKE: an insert between two requests shifts the window, so the next
-- OFFSET page repeats the last row the client already has.
CREATE TABLE page1 AS
SELECT id FROM orders WHERE customer_id = 3
ORDER BY created_at DESC, id DESC LIMIT 20 OFFSET 0;
INSERT INTO orders (id, customer_id, total_cents, created_at) VALUES (100001, 3, 100, timestamptz '2027-01-01 00:00:00+00');
CREATE TABLE page2 AS
SELECT id FROM orders WHERE customer_id = 3
ORDER BY created_at DESC, id DESC LIMIT 20 OFFSET 20;
SELECT assert_true((SELECT count(*) FROM page2 JOIN page1 USING (id)) = 1, 'a row appears on both pages');

-- 2. N+1: one query for the page, then one query per order for its items.
-- The DO block stands in for the application loop; from a client, each
-- iteration is also a network round trip.
SELECT pg_stat_statements_reset();
DO $$
DECLARE
  o record;
  n int;
BEGIN
  FOR o IN SELECT id FROM orders WHERE customer_id = 3 ORDER BY created_at DESC, id DESC LIMIT 20 LOOP
    -- MISTAKE: a query per row. 20 orders cost 21 statements instead of 1.
    SELECT count(*) INTO n FROM order_items WHERE order_id = o.id;
  END LOOP;
END
$$;
SELECT assert_true(
    (SELECT sum(calls) FROM pg_stat_statements
     WHERE query ILIKE 'SELECT count(*)%FROM order_items WHERE order_id%') = 20,
    'the item lookup ran once per order');

-- 3. Row-by-row inserts.
SELECT pg_stat_statements_reset();
DO $$
BEGIN
  FOR o IN 1..250 LOOP
    FOR n IN 1..4 LOOP
      -- MISTAKE: one INSERT per row. 1,000 rows cost 1,000 statements (and,
      -- from a client in autocommit, 1,000 round trips and 1,000 commits)
      -- where one unnest INSERT or a COPY does the same work.
      INSERT INTO order_items (order_id, sku, qty) VALUES (o, 'extra-' || n, 1);
    END LOOP;
  END LOOP;
END
$$;
SELECT assert_true(
    (SELECT sum(calls) FROM pg_stat_statements WHERE query ILIKE 'INSERT INTO order_items%') = 1000,
    'the loop ran 1,000 INSERT statements');
SELECT assert_true((SELECT count(*) FROM order_items WHERE sku LIKE 'extra-%') = 1000, 'for 1,000 rows');

-- 4. Read-then-write instead of an upsert.
CREATE TABLE stock (sku text PRIMARY KEY, available int NOT NULL);
-- MISTAKE: check, then insert. Two sessions can both see "no row"; the second
-- INSERT then fails with unique_violation instead of updating, and the check
-- is an extra statement every time.
INSERT INTO stock (sku, available) SELECT 'sku-1', 10 WHERE NOT EXISTS (SELECT 1 FROM stock WHERE sku = 'sku-1');
SELECT assert_error($q$INSERT INTO stock (sku, available) VALUES ('sku-1', 11)$q$, '23505',
    'the concurrent writer that skipped the check fails with a duplicate key');

-- 5. SELECT *.
-- MISTAKE: SELECT * pulls every column, including ones the page never shows,
-- so the index cannot answer the query alone and every row visits the heap.
SELECT assert_true(
    NOT plan_has('SELECT * FROM orders WHERE customer_id = 5 ORDER BY created_at DESC, id DESC LIMIT 20', 'Index Only Scan'),
    'SELECT * rules out an Index Only Scan');
