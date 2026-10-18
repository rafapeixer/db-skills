-- pg-indexing, good example: each index matches the query it serves.
-- 20k customers, 300k orders, statistics and visibility map up to date.

CREATE TABLE customers (
  id bigint PRIMARY KEY,
  email text NOT NULL
);

CREATE TABLE orders (
  id bigint PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers (id),
  status text NOT NULL,
  created_at timestamptz NOT NULL,
  total numeric(10, 2) NOT NULL
);

INSERT INTO customers
SELECT g, 'User' || g || '@Example.com' FROM generate_series(1, 20000) g;

-- 1% pending, 9% cancelled, 90% shipped; about 15 orders per customer.
INSERT INTO orders
SELECT g, 1 + (g::bigint * 7919) % 20000,
       CASE WHEN g % 100 = 0 THEN 'pending' WHEN g % 10 = 0 THEN 'cancelled' ELSE 'shipped' END,
       timestamptz '2026-01-01' + g * interval '1 minute',
       (g % 500) + 0.99
FROM generate_series(1, 300000) g;

-- Equality column first, then the range/sort column; total rides along for index-only scans.
-- The leading customer_id also serves the foreign key check on DELETE FROM customers.
CREATE INDEX orders_customer_created_idx ON orders (customer_id, created_at) INCLUDE (total);

-- Only the 1% hot subset the worker polls.
CREATE INDEX orders_pending_created_idx ON orders (created_at) WHERE status = 'pending';

-- Same expression the login query uses.
CREATE INDEX customers_email_lower_idx ON customers (lower(email));

-- Low-cardinality leading column (3 values); PG 18+ skip scan also uses it for created_at-only filters.
CREATE INDEX orders_status_created_idx ON orders (status, created_at);

-- VACUUM sets the visibility map bits that index-only scans need.
VACUUM ANALYZE customers;
VACUUM ANALYZE orders;

-- index_used reports whether the plan reads the named index.
CREATE FUNCTION index_used(query text, index_name text) RETURNS boolean
LANGUAGE sql AS $$
  SELECT jsonb_path_exists(plan_json(query), '$.** ? (@."Index Name" == $i)', jsonb_build_object('i', index_name));
$$;

-- buffers_touched runs the query and returns the shared buffers it hit or read.
CREATE FUNCTION buffers_touched(query text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  plan jsonb;
BEGIN
  EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || query INTO plan;
  RETURN (plan -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint
       + (plan -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint;
END
$$;

-- 1. WHERE a = ? AND b > ? ORDER BY b: one index range, rows already in order, no heap visits.
SELECT assert_true(
  plan_has($q$SELECT created_at, total FROM orders WHERE customer_id = 42 AND created_at >= '2026-03-01' ORDER BY created_at LIMIT 20$q$, 'Index Only Scan'),
  'covering composite index gives an Index Only Scan');
SELECT assert_true(
  NOT plan_has($q$SELECT created_at, total FROM orders WHERE customer_id = 42 AND created_at >= '2026-03-01' ORDER BY created_at LIMIT 20$q$, 'Sort'),
  'index order satisfies ORDER BY created_at, no Sort node');
SELECT assert_true(
  buffers_touched($q$SELECT created_at, total FROM orders WHERE customer_id = 42 AND created_at >= '2026-03-01' ORDER BY created_at LIMIT 20$q$) < 10,
  'the customer''s recent orders cost a handful of buffers');

-- 2. Hot subset: the worker query repeats the partial index predicate literally.
SELECT assert_true(
  index_used($q$SELECT id, created_at FROM orders WHERE status = 'pending' ORDER BY created_at LIMIT 50$q$, 'orders_pending_created_idx'),
  'partial index serves the pending queue');
SELECT assert_true(
  NOT plan_has($q$SELECT id, created_at FROM orders WHERE status = 'pending' ORDER BY created_at LIMIT 50$q$, 'Sort'),
  'pending queue is read in created_at order without a Sort');
SELECT assert_true(
  (SELECT pg_relation_size('orders_pending_created_idx') * 20 < pg_relation_size('orders_status_created_idx')),
  'partial index is under 5% of the size of a full index on the same table');

-- 3. Expression index: the query uses the same lower(email) expression.
SELECT assert_true(
  index_used($q$SELECT id FROM customers WHERE lower(email) = 'user42@example.com'$q$, 'customers_email_lower_idx'),
  'case-insensitive login uses the expression index');

-- 4. The foreign key check run by DELETE FROM customers finds child rows through the index.
SELECT assert_true(
  NOT plan_has($q$SELECT 1 FROM orders WHERE customer_id = 42$q$, 'Seq Scan'),
  'child lookup by customer_id never scans orders');

-- Every foreign key has an index whose leading columns are the FK columns.
SELECT assert_true(NOT EXISTS (
  SELECT 1
  FROM pg_constraint c
  WHERE c.contype = 'f'
    AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = c.conrelid
        AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] = c.conkey)
), 'no foreign key without a supporting index');

-- No index whose key columns are a leading prefix of another index on the same table.
SELECT assert_true(NOT EXISTS (
  SELECT 1
  FROM pg_index a
  JOIN pg_index b ON a.indrelid = b.indrelid AND a.indexrelid <> b.indexrelid
  WHERE NOT a.indisunique
    AND a.indpred IS NULL AND b.indpred IS NULL
    AND a.indexprs IS NULL AND b.indexprs IS NULL
    AND a.indnkeyatts <= b.indnkeyatts
    AND (a.indkey::int2[])[0:a.indnkeyatts - 1] = (b.indkey::int2[])[0:a.indnkeyatts - 1]
), 'no duplicate or prefix-redundant index');

-- 5. Skip scan (PG 18+): a filter on created_at alone uses the (status, created_at) index.
DO $$
DECLARE
  q text := $q$SELECT count(*) FROM orders WHERE created_at >= '2026-02-01' AND created_at < '2026-02-01 02:00'$q$;
BEGIN
  IF current_setting('server_version_num')::int >= 180000 THEN
    PERFORM assert_true(index_used(q, 'orders_status_created_idx'), 'PG 18 skip scan uses the low-cardinality leading index');
  ELSE
    PERFORM assert_true(plan_has(q, 'Seq Scan'), 'before PG 18 the same filter scans the whole table');
  END IF;
END
$$;
