-- Good: one statement per page, keyset pagination, set-based writes,
-- idempotent upserts and RETURNING instead of a read-back.

CREATE TABLE orders (
    id          bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    total_cents bigint NOT NULL,
    status      text NOT NULL DEFAULT 'new',
    note        text,
    created_at  timestamptz NOT NULL
);
-- The keyset index: equality column first, then the sort key, then the
-- unique tie-breaker.
CREATE INDEX orders_customer_created_id ON orders (customer_id, created_at, id);

CREATE TABLE order_items (
    order_id bigint NOT NULL REFERENCES orders (id),
    sku      text NOT NULL,
    qty      int NOT NULL,
    PRIMARY KEY (order_id, sku)
);

-- 100,000 orders for 10 customers, three items each.
INSERT INTO orders (id, customer_id, total_cents, created_at)
SELECT g, g % 10 + 1, g * 7 % 10000, timestamptz '2026-01-01 00:00:00+00' + g * interval '1 minute'
FROM generate_series(1, 100000) AS g;

INSERT INTO order_items (order_id, sku, qty)
SELECT o, 'sku-' || n, (o + n) % 5 + 1
FROM generate_series(1, 100000) AS o, generate_series(1, 3) AS n;

-- The newest order of customer 3 has no items yet.
INSERT INTO orders (id, customer_id, total_cents, created_at)
VALUES (100001, 3, 500, timestamptz '2026-12-31 00:00:00+00');

VACUUM ANALYZE orders;
VACUUM ANALYZE order_items;

-- scanned_rows runs a query with EXPLAIN ANALYZE and returns how many rows
-- the scans of one table produced, so a test can prove how much work a page
-- does, not only which plan it uses.
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

-- 1. A page of orders with their items in one statement. The keyset WHERE,
-- ORDER BY and LIMIT sit in a subquery, so the LATERAL runs once per row of
-- the page; coalesce keeps orders that have no items.
CREATE VIEW first_page AS
SELECT o.id, o.total_cents, o.created_at,
       coalesce(i.skus, '{}') AS skus, coalesce(i.qtys, '{}') AS qtys
FROM (
    SELECT id, total_cents, created_at FROM orders
    WHERE customer_id = 3
    ORDER BY created_at DESC, id DESC
    LIMIT 20
) o
LEFT JOIN LATERAL (
    SELECT array_agg(sku ORDER BY sku) AS skus, array_agg(qty ORDER BY sku) AS qtys
    FROM order_items WHERE order_id = o.id
) i ON true;

SELECT assert_true((SELECT count(*) FROM first_page) = 20, 'the page has 20 orders');
SELECT assert_true((SELECT skus FROM first_page WHERE id = 100001) = '{}', 'an order without items keeps an empty array');
SELECT assert_true((SELECT skus FROM first_page WHERE id = 99992) = '{sku-1,sku-2,sku-3}', 'each order carries its own items');
SELECT assert_true((SELECT count(*) FROM first_page WHERE cardinality(skus) = 3) = 19, 'the other 19 orders have three items each');
SELECT assert_true(plan_has('SELECT id, skus, qtys FROM first_page', 'Index Scan'), 'orders and items are read through indexes');
SELECT assert_true(NOT plan_has('SELECT id, skus, qtys FROM first_page', 'Seq Scan'), 'no table is scanned in full');
SELECT assert_true(NOT plan_has('SELECT id, skus, qtys FROM first_page', 'Sort'), 'the index already returns the page in order');
SELECT assert_true(scanned_rows('SELECT id, skus, qtys FROM first_page', 'order_items') <= 60, 'items are read only for the 20 orders on the page (57 rows of 300,000)');

-- 2. Keyset pagination: the next page starts after the last row of this one.
-- (created_at, id) < (...) is a row comparison the index can range-scan.
CREATE FUNCTION keyset_page(after_created timestamptz, after_id bigint) RETURNS TABLE (id bigint, created_at timestamptz)
LANGUAGE sql AS $$
    SELECT id, created_at FROM orders
    WHERE customer_id = 3 AND (created_at, id) < (after_created, after_id)
    ORDER BY created_at DESC, id DESC
    LIMIT 20
$$;

SELECT assert_true(
    plan_has($q$SELECT id, created_at FROM orders
                WHERE customer_id = 3 AND (created_at, id) < ('2026-01-08 00:00:00+00', 10000)
                ORDER BY created_at DESC, id DESC LIMIT 20$q$, 'Index Only Scan'),
    'a keyset page is an index range scan');
SELECT assert_true(
    NOT plan_has($q$SELECT id, created_at FROM orders
                    WHERE customer_id = 3 AND (created_at, id) < ('2026-01-08 00:00:00+00', 10000)
                    ORDER BY created_at DESC, id DESC LIMIT 20$q$, 'Sort'),
    'a keyset page needs no Sort');
-- The deepest page reads 20 rows, the same as the first.
SELECT assert_true(
    scanned_rows($q$SELECT id, created_at FROM orders
                    WHERE customer_id = 3 AND (created_at, id) < ('2026-01-01 08:00:00+00', 480)
                    ORDER BY created_at DESC, id DESC LIMIT 20$q$, 'orders') <= 20,
    'a deep keyset page reads only the rows it returns');
-- A row inserted between two requests does not shift the next page.
CREATE TABLE page1 AS SELECT id, created_at FROM keyset_page('infinity', 0);
INSERT INTO orders (id, customer_id, total_cents, created_at) VALUES (100002, 3, 100, timestamptz '2027-01-01 00:00:00+00');
CREATE TABLE page2 AS
SELECT p.id FROM (SELECT created_at, id FROM page1 ORDER BY created_at, id LIMIT 1) AS last,
     LATERAL keyset_page(last.created_at, last.id) AS p;
SELECT assert_true((SELECT count(*) FROM page2) = 20, 'the second page is full');
SELECT assert_true(NOT EXISTS (SELECT 1 FROM page2 JOIN page1 USING (id)), 'no row appears on both pages');

-- 3. Batch writes: one statement for the order and all its items. The arrays
-- arrive as two parameters from the application ($1::text[], $2::int[]).
WITH new_order AS (
    INSERT INTO orders (id, customer_id, total_cents, created_at)
    VALUES (200001, 4, 4200, now())
    RETURNING id
), new_items AS (
    INSERT INTO order_items (order_id, sku, qty)
    SELECT new_order.id, item.sku, item.qty
    FROM new_order, unnest(ARRAY['sku-a', 'sku-b', 'sku-c'], ARRAY[2, 1, 5]) AS item (sku, qty)
    RETURNING order_id
)
SELECT assert_true((SELECT count(*) FROM new_items) = 3, 'one statement inserts the order and its three items');

SELECT assert_true((SELECT sum(qty) FROM order_items WHERE order_id = 200001) = 8, 'unnest pairs the arrays element by element');

-- COPY for bulk loads.
COPY order_items (order_id, sku, qty) FROM STDIN WITH (FORMAT csv);
200001,sku-d,1
200001,sku-e,2
\.
SELECT assert_true((SELECT count(*) FROM order_items WHERE order_id = 200001) = 5, 'COPY added two more items');

-- 4. Upsert with ON CONFLICT: running the same batch twice changes nothing
-- the second time, and the WHERE skips rows whose value did not change.
CREATE TABLE stock (
    sku       text PRIMARY KEY,
    available int NOT NULL
);

CREATE TABLE upsert_runs (run int, changed bigint);
WITH changed AS (
    INSERT INTO stock AS s (sku, available)
    SELECT * FROM unnest(ARRAY['sku-1', 'sku-2', 'sku-3'], ARRAY[10, 20, 30])
    ON CONFLICT (sku) DO UPDATE SET available = EXCLUDED.available
    WHERE s.available IS DISTINCT FROM EXCLUDED.available
    RETURNING sku
)
INSERT INTO upsert_runs SELECT 1, count(*) FROM changed;
-- Same statement again, with one value changed.
WITH changed AS (
    INSERT INTO stock AS s (sku, available)
    SELECT * FROM unnest(ARRAY['sku-1', 'sku-2', 'sku-3'], ARRAY[10, 20, 31])
    ON CONFLICT (sku) DO UPDATE SET available = EXCLUDED.available
    WHERE s.available IS DISTINCT FROM EXCLUDED.available
    RETURNING sku
)
INSERT INTO upsert_runs SELECT 2, count(*) FROM changed;

SELECT assert_true((SELECT changed FROM upsert_runs WHERE run = 1) = 3, 'the first run inserts three rows');
SELECT assert_true((SELECT changed FROM upsert_runs WHERE run = 2) = 1, 'the rerun writes only the row that changed');
SELECT assert_true((SELECT count(*) FROM stock) = 3, 'no duplicate rows');
SELECT assert_true((SELECT available FROM stock WHERE sku = 'sku-3') = 31, 'the changed value is stored');

-- 5. RETURNING gives the written row back without a second SELECT.
CREATE TABLE returned (id bigint, status text, total_cents bigint);
WITH upd AS (
    UPDATE orders SET status = 'paid' WHERE id = 200001
    RETURNING id, status, total_cents
)
INSERT INTO returned SELECT * FROM upd;
SELECT assert_true((SELECT status FROM returned) = 'paid', 'RETURNING shows the new value');

-- PostgreSQL 18+: RETURNING old and new values in the same statement.
DO $$
DECLARE
  before_status text;
  after_status  text;
BEGIN
  IF current_setting('server_version_num')::int < 180000 THEN
    RETURN;
  END IF;
  EXECUTE $q$
    UPDATE orders SET status = 'shipped' WHERE id = 200001
    RETURNING old.status, new.status
  $q$ INTO before_status, after_status;
  PERFORM assert_true(before_status = 'paid' AND after_status = 'shipped', 'RETURNING old/new shows both versions');
END
$$;

-- 6. Named columns: the list query reads only the index.
SELECT assert_true(
    plan_has('SELECT id, created_at FROM orders WHERE customer_id = 5 ORDER BY created_at DESC, id DESC LIMIT 20', 'Index Only Scan'),
    'naming indexed columns allows an Index Only Scan');
