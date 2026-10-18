-- Bad: a page loaded with N+1 queries, an order written one statement per
-- round trip inside BEGIN/COMMIT, a queue claimed with plain FOR UPDATE and
-- work inside the transaction, and one hot counter row every request updates.
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

CREATE TABLE stock (sku text PRIMARY KEY, qty bigint NOT NULL);
INSERT INTO stock VALUES ('SKU-1', 16000);
ANALYZE;

CREATE ROLE tp_bad_app LOGIN;
ALTER ROLE tp_bad_app SET pg_stat_statements.track = 'all';
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO tp_bad_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO tp_bad_app;

-- Statements the application session sent since the last reset.
CREATE FUNCTION round_trips() RETURNS bigint LANGUAGE sql AS $$
  SELECT coalesce(sum(calls), 0)::bigint FROM pg_stat_statements
  WHERE userid = 'tp_bad_app'::regrole
    AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database());
$$;

SELECT dblink_connect('app', 'dbname=' || current_database() || ' user=tp_bad_app');
SELECT pid AS app_pid FROM dblink('app', 'SELECT pg_backend_pid()') AS r(pid int) \gset

-- 1. N+1: the page, then one query per order for its items.
SELECT pg_stat_statements_reset();
CREATE TEMP TABLE page AS
SELECT * FROM dblink('app', $q$
SELECT id FROM orders WHERE customer_id = 7 ORDER BY created_at DESC, id DESC LIMIT 10
$q$) AS t(id bigint);
-- The DO block stands in for the application loop.
DO $$
DECLARE
  o record;
BEGIN
  FOR o IN SELECT id FROM page LOOP
    -- MISTAKE: one query per order. 10 orders cost 11 round trips; at 0.5 ms
    -- each the connection is held for 5.5 ms of network alone, and the
    -- benchmark's naive page got 146 tps per connection against 1,473.
    PERFORM * FROM dblink('app', format('SELECT sku, qty FROM order_items WHERE order_id = %s', o.id)) AS t(sku text, qty int);
  END LOOP;
END
$$;
SELECT assert_true(round_trips() = 11, 'the page and its items cost 11 round trips');

-- 2. An order and its items, one statement per round trip in a transaction.
SELECT pg_stat_statements_reset();
SELECT dblink_exec('app', 'BEGIN');
SELECT id AS order_id FROM dblink('app', $q$
INSERT INTO orders (customer_id, status, total) VALUES (7, 'new', 30.00) RETURNING id
$q$) AS t(id bigint) \gset
-- MISTAKE: between round trips the connection sits idle in transaction,
-- holding its locks, waiting for the application to send the next INSERT.
SELECT assert_true((SELECT state FROM pg_stat_activity WHERE pid = :app_pid) = 'idle in transaction', 'the connection waits idle in transaction between statements');
SELECT dblink_exec('app', format('INSERT INTO order_items (order_id, sku, qty) VALUES (%s, %L, %s)', :order_id, 'A1', 1));
SELECT dblink_exec('app', format('INSERT INTO order_items (order_id, sku, qty) VALUES (%s, %L, %s)', :order_id, 'B1', 2));
SELECT dblink_exec('app', format('INSERT INTO order_items (order_id, sku, qty) VALUES (%s, %L, %s)', :order_id, 'C1', 3));
SELECT dblink_exec('app', 'COMMIT');
-- MISTAKE: BEGIN + 4 INSERTs + COMMIT is 6 round trips for what one
-- WITH ... INSERT ... RETURNING statement does in 1.
SELECT assert_true(round_trips() = 6, 'the order and its 3 items cost 6 round trips');
SELECT assert_true((SELECT count(*) FROM order_items WHERE order_id = :order_id) = 3, 'for the same 3 items');

-- 3. Queue claimed with plain FOR UPDATE, work done inside the transaction.
SELECT dblink_exec('app', 'BEGIN');
-- MISTAKE: no SKIP LOCKED, and the job runs before COMMIT: every other
-- worker waits on this row for as long as the job takes.
SELECT id AS w1_job FROM dblink('app', $q$
SELECT id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE
$q$) AS t(id bigint) \gset
-- Worker 2 runs the same claim. lock_timeout is set only so the example can
-- assert the wait; without it, worker 2 waits until worker 1 commits.
BEGIN;
SET LOCAL lock_timeout = '200ms';
SELECT assert_error($q$SELECT id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE$q$, '55P03', 'worker 2 waits on the row worker 1 is working on');
COMMIT;
SELECT dblink_exec('app', 'UPDATE jobs SET status = ''done'', claimed_at = now() WHERE id = ' || :w1_job);
SELECT dblink_exec('app', 'COMMIT');

-- 4. Hot counter: every sale updates the same row.
SELECT dblink_exec('app', 'BEGIN');
SELECT dblink_exec('app', $q$UPDATE stock SET qty = qty - 1 WHERE sku = 'SKU-1'$q$);
-- MISTAKE: one row for every request. The row lock lasts until the sale
-- commits, so concurrent sales run one at a time; in the benchmark this row
-- peaked at 1,671 tps with 4 connections and fell to 1,348 with 64.
BEGIN;
SET LOCAL lock_timeout = '200ms';
SELECT assert_error($q$UPDATE stock SET qty = qty - 1 WHERE sku = 'SKU-1'$q$, '55P03', 'a second sale waits for the first to commit');
COMMIT;
SELECT dblink_exec('app', 'COMMIT');
SELECT assert_true((SELECT qty FROM stock WHERE sku = 'SKU-1') = 15999, 'only the first sale went through');

SELECT dblink_disconnect('app');
DROP OWNED BY tp_bad_app;
DROP ROLE tp_bad_app;
