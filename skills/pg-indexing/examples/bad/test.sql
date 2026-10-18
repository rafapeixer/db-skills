-- pg-indexing, bad example: same tables and queries as the good example,
-- with the indexes agents usually create instead.

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

INSERT INTO orders
SELECT g, 1 + (g::bigint * 7919) % 20000,
       CASE WHEN g % 100 = 0 THEN 'pending' WHEN g % 10 = 0 THEN 'cancelled' ELSE 'shipped' END,
       timestamptz '2026-01-01' + g * interval '1 minute',
       (g % 500) + 0.99
FROM generate_series(1, 300000) g;

-- MISTAKE: range column first. The scan walks every order since March to find one customer's 15 rows.
CREATE INDEX orders_created_customer_idx ON orders (created_at, customer_id);

-- MISTAKE: plain column index, but the login query compares lower(email). The index is never used.
CREATE INDEX customers_email_idx ON customers (email);

-- MISTAKE: a second index on the same leading column, "just in case". Every insert pays for both.
CREATE INDEX orders_status_idx ON orders (status);
CREATE INDEX orders_status_created_idx ON orders (status, created_at);

-- MISTAKE: no index leads with orders.customer_id, so each DELETE FROM customers scans all of orders.

VACUUM ANALYZE customers;
VACUUM ANALYZE orders;

CREATE FUNCTION index_used(query text, index_name text) RETURNS boolean
LANGUAGE sql AS $$
  SELECT jsonb_path_exists(plan_json(query), '$.** ? (@."Index Name" == $i)', jsonb_build_object('i', index_name));
$$;

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

-- 1. Wrong column order: no index-only scan, and hundreds of buffers for 15 rows.
SELECT assert_true(
  NOT plan_has($q$SELECT created_at, total FROM orders WHERE customer_id = 42 AND created_at >= '2026-03-01' ORDER BY created_at LIMIT 20$q$, 'Index Only Scan'),
  'range-first index cannot answer the query from the index alone');
SELECT assert_true(
  buffers_touched($q$SELECT created_at, total FROM orders WHERE customer_id = 42 AND created_at >= '2026-03-01' ORDER BY created_at LIMIT 20$q$) > 500,
  'range-first index reads the whole created_at range to find one customer');

-- 2. Latest orders for a customer: nothing leads with customer_id, so PostgreSQL scans and sorts.
SELECT assert_true(
  plan_has($q$SELECT id, total FROM orders WHERE customer_id = 42 ORDER BY id DESC LIMIT 20$q$, 'Seq Scan')
  OR plan_has($q$SELECT id, total FROM orders WHERE customer_id = 42 ORDER BY id DESC LIMIT 20$q$, 'Sort'),
  'customer order history is a full scan or a sort, not an index range');

-- 3. Unindexed foreign key: the check behind DELETE FROM customers is a Seq Scan on orders.
SELECT assert_true(
  plan_has($q$SELECT 1 FROM orders WHERE customer_id = 42$q$, 'Seq Scan'),
  'child lookup by customer_id scans the whole orders table');
SELECT assert_true(EXISTS (
  SELECT 1
  FROM pg_constraint c
  WHERE c.contype = 'f'
    AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = c.conrelid
        AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] = c.conkey)
), 'orders.customer_id foreign key has no supporting index');

-- 4. Expression mismatch: the index on email does nothing for lower(email).
SELECT assert_true(
  plan_has($q$SELECT id FROM customers WHERE lower(email) = 'user42@example.com'$q$, 'Seq Scan'),
  'lower(email) cannot use an index on email');
SELECT assert_true(
  NOT index_used($q$SELECT id FROM customers WHERE lower(email) = 'user42@example.com'$q$, 'customers_email_idx'),
  'the plain email index is dead weight for this query');

-- 5. Redundant index: (status) is a prefix of (status, created_at) and costs space on every write.
SELECT assert_true(EXISTS (
  SELECT 1
  FROM pg_index a
  JOIN pg_index b ON a.indrelid = b.indrelid AND a.indexrelid <> b.indexrelid
  WHERE NOT a.indisunique
    AND a.indpred IS NULL AND b.indpred IS NULL
    AND a.indexprs IS NULL AND b.indexprs IS NULL
    AND a.indnkeyatts <= b.indnkeyatts
    AND (a.indkey::int2[])[0:a.indnkeyatts - 1] = (b.indkey::int2[])[0:a.indnkeyatts - 1]
), 'orders_status_idx duplicates the leading column of orders_status_created_idx');
SELECT assert_true(
  pg_relation_size('orders_status_idx') > 1024 * 1024,
  'the redundant index still occupies more than 1 MB');
