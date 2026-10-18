-- Good: each request is one statement (one round trip), a queue claim that
-- never waits on another worker, and a hot counter split into shards.
-- A second session, opened with dblink as its own role, plays the
-- application: every dblink call is one round trip on its connection, and
-- pg_stat_statements counts that role's statements.
CREATE EXTENSION dblink;
SET pg_stat_statements.track = 'all';

CREATE TABLE orders (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL,
  status      text NOT NULL,
  total       numeric(12, 2) NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_created ON orders (customer_id, created_at DESC, id DESC);
CREATE TABLE order_items (
  order_id bigint NOT NULL REFERENCES orders (id),
  sku      text NOT NULL,
  qty      int NOT NULL,
  PRIMARY KEY (order_id, sku)
);
INSERT INTO orders (customer_id, status, total, created_at)
SELECT 1 + g % 2000, 'paid', (g % 500) + 0.99, now() - g * interval '1 second'
FROM generate_series(1, 40000) AS g;
INSERT INTO order_items (order_id, sku, qty)
SELECT o.id, s.sku || (o.id % 300), 1 + o.id % 3
FROM orders o CROSS JOIN (VALUES ('A'), ('B'), ('C')) AS s(sku);

CREATE TABLE jobs (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  status     text NOT NULL DEFAULT 'pending',
  claimed_at timestamptz
);
CREATE INDEX jobs_pending ON jobs (id) WHERE status = 'pending';
INSERT INTO jobs (status) SELECT 'pending' FROM generate_series(1, 100);

-- 16 shards of 1,000 units each: the stock of SKU-1 is their sum, 16,000.
CREATE TABLE stock_shards (
  sku   text NOT NULL,
  shard int NOT NULL,
  qty   bigint NOT NULL,
  PRIMARY KEY (sku, shard)
);
INSERT INTO stock_shards SELECT 'SKU-1', s, 1000 FROM generate_series(0, 15) AS s;
ANALYZE;

CREATE ROLE tp_good_app LOGIN;
ALTER ROLE tp_good_app SET pg_stat_statements.track = 'all';
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO tp_good_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO tp_good_app;

-- Statements the application session sent since the last reset.
CREATE FUNCTION round_trips() RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce(sum(calls), 0)::bigint FROM pg_stat_statements
  WHERE userid = 'tp_good_app'::regrole
    AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database());
$$;

SELECT dblink_connect('app', 'dbname=' || current_database() || ' user=tp_good_app');
SELECT pid AS app_pid FROM dblink('app', 'SELECT pg_backend_pid()') AS r(pid int) \gset

-- 1. A page of orders with their items: one statement, one round trip.
SELECT pg_stat_statements_reset();
CREATE TEMP TABLE page AS
SELECT * FROM dblink('app', $q$
SELECT o.id, o.created_at, i.skus, i.qtys
FROM (SELECT id, created_at FROM orders WHERE customer_id = 7
      ORDER BY created_at DESC, id DESC LIMIT 10) o
LEFT JOIN LATERAL (SELECT array_agg(sku ORDER BY sku) AS skus, array_agg(qty ORDER BY sku) AS qtys
                   FROM order_items WHERE order_id = o.id) i ON true
ORDER BY o.created_at DESC, o.id DESC
$q$) AS t(id bigint, created_at timestamptz, skus text[], qtys int[]);
SELECT assert_true(round_trips() = 1, 'the page and its items cost 1 round trip');
SELECT assert_true((SELECT count(*) FROM page) = 10, 'the page has 10 orders');
SELECT assert_true((SELECT bool_and(cardinality(skus) = 3) FROM page), 'each order comes with its 3 items');

-- 2. An order and its items: one statement, which is also one transaction.
SELECT pg_stat_statements_reset();
CREATE TEMP TABLE written AS
SELECT * FROM dblink('app', $q$
WITH o AS (
  INSERT INTO orders (customer_id, status, total) VALUES (7, 'new', 30.00) RETURNING id
)
INSERT INTO order_items (order_id, sku, qty)
SELECT o.id, v.sku, v.qty FROM o, (VALUES ('A1', 1), ('B1', 2), ('C1', 3)) AS v(sku, qty)
RETURNING order_id
$q$) AS t(order_id bigint);
SELECT assert_true(round_trips() = 1, 'the order and its 3 items cost 1 round trip');
SELECT assert_true((SELECT count(DISTINCT order_id) = 1 AND count(*) = 3 FROM written), 'one order, 3 items');
SELECT assert_true(
    (SELECT count(*) FROM order_items WHERE order_id = (SELECT max(order_id) FROM written)) = 3,
    'the items are stored');
-- All or nothing without BEGIN/COMMIT: a duplicate item fails the statement
-- and the order row it inserted is rolled back with it.
SELECT assert_true(dblink_exec('app', $q$
WITH o AS (
  INSERT INTO orders (customer_id, status, total) VALUES (7, 'new', 99.00) RETURNING id
)
INSERT INTO order_items (order_id, sku, qty)
SELECT o.id, v.sku, v.qty FROM o, (VALUES ('A1', 1), ('A1', 2)) AS v(sku, qty)
$q$, false) = 'ERROR', 'a duplicate item fails the whole statement');
SELECT assert_true(NOT EXISTS (SELECT 1 FROM orders WHERE total = 99.00), 'the failed statement left no order behind');

-- 3. Queue: claim with SKIP LOCKED in one statement.
-- Worker 1 has claimed a job and its transaction is still open.
SELECT dblink_exec('app', 'BEGIN');
SELECT id AS w1_job FROM dblink('app', $q$
UPDATE jobs SET status = 'running', claimed_at = now()
WHERE id = (SELECT id FROM jobs WHERE status = 'pending'
            ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING id
$q$) AS t(id bigint) \gset
-- Worker 2 runs the same claim at the same moment. lock_timeout is a safety
-- net: SKIP LOCKED never waits, so it never fires.
BEGIN;
SET LOCAL lock_timeout = '200ms';
UPDATE jobs SET status = 'running', claimed_at = now()
WHERE id = (SELECT id FROM jobs WHERE status = 'pending'
            ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING id AS w2_job \gset
SELECT assert_true(:w1_job = 1 AND :w2_job = 2, 'the two workers got different jobs');
SELECT assert_true(NOT EXISTS (SELECT 1 FROM pg_locks WHERE NOT granted), 'nobody waited on a lock');
COMMIT;
SELECT dblink_exec('app', 'COMMIT');

-- Claim, commit, then work: in autocommit the claim is its own transaction,
-- so the connection is idle and holds no locks while the job runs.
SELECT id AS w1_next FROM dblink('app', $q$
UPDATE jobs SET status = 'running', claimed_at = now()
WHERE id = (SELECT id FROM jobs WHERE status = 'pending'
            ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING id
$q$) AS t(id bigint) \gset
SELECT assert_true(:w1_next = 3, 'the next claim skips the jobs already running');
SELECT assert_true((SELECT state FROM pg_stat_activity WHERE pid = :app_pid) = 'idle', 'the worker connection is idle, not idle in transaction, while it works');
SELECT assert_true(NOT EXISTS (SELECT 1 FROM pg_locks WHERE pid = :app_pid AND locktype = 'transactionid'), 'and holds no transaction');
SELECT dblink_exec('app', 'UPDATE jobs SET status = ''done'' WHERE id = ' || :w1_next);

-- 4. Hot counter: each sale decrements one random shard.
-- The scalar subquery runs once, so exactly one row changes; random() written
-- directly in the WHERE clause would be re-evaluated for every row.
UPDATE stock_shards SET qty = qty - 1
WHERE sku = 'SKU-1' AND shard = (SELECT floor(random() * 16)::int);
SELECT assert_true((SELECT sum(qty) FROM stock_shards WHERE sku = 'SKU-1') = 15999, 'one sale, one unit');

-- A sale holding shard 0 does not block a sale on shard 1.
SELECT dblink_exec('app', 'BEGIN');
SELECT dblink_exec('app', $q$UPDATE stock_shards SET qty = qty - 1 WHERE sku = 'SKU-1' AND shard = 0$q$);
BEGIN;
SET LOCAL lock_timeout = '200ms';
UPDATE stock_shards SET qty = qty - 1 WHERE sku = 'SKU-1' AND shard = 1;
COMMIT;
-- Readers are never blocked: the sum shows every committed sale.
SELECT assert_true((SELECT sum(qty) FROM stock_shards WHERE sku = 'SKU-1') = 15998, 'the read does not wait for the open sale');
SELECT dblink_exec('app', 'COMMIT');

-- Two sessions sell 500 units each at the same time, one transaction per sale.
SELECT dblink_send_query('app', $q$
DO $$
BEGIN
  FOR i IN 1..500 LOOP
    UPDATE stock_shards SET qty = qty - 1
    WHERE sku = 'SKU-1' AND shard = (SELECT floor(random() * 16)::int);
    COMMIT;
  END LOOP;
END
$$
$q$);
DO $$
BEGIN
  FOR i IN 1..500 LOOP
    UPDATE stock_shards SET qty = qty - 1
    WHERE sku = 'SKU-1' AND shard = (SELECT floor(random() * 16)::int);
    COMMIT;
  END LOOP;
END
$$;
SELECT * FROM dblink_get_result('app') AS t(status text);
SELECT * FROM dblink_get_result('app') AS t(status text);
SELECT assert_true((SELECT sum(qty) FROM stock_shards WHERE sku = 'SKU-1') = 14997, 'the shards add up to 16,000 minus 1,003 sales');
SELECT assert_true((SELECT count(*) FROM stock_shards WHERE sku = 'SKU-1') = 16, 'still 16 shards');

SELECT dblink_disconnect('app');
DROP OWNED BY tp_good_app;
DROP ROLE tp_good_app;
