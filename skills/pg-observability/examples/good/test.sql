-- Good: find the queries that cost the most with pg_stat_statements,
-- ranked by total_exec_time, and read plans without changing data.
-- The test server preloads pg_stat_statements and the helpers run
-- CREATE EXTENSION in this database.

CREATE TABLE obs_orders (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL,
  amount      numeric(10, 2) NOT NULL,
  status      text NOT NULL
);
INSERT INTO obs_orders (customer_id, amount, status)
SELECT g % 5000, (g % 1000) / 10.0, CASE WHEN g % 10 = 0 THEN 'refunded' ELSE 'paid' END
FROM generate_series(1, 200000) AS g;
ANALYZE obs_orders;

-- The defaults: I/O timing and slow-statement logging are off, the
-- statement table holds 5000 entries.
SELECT assert_true(boot_val = 'off', 'track_io_timing is off by default')
FROM pg_settings WHERE name = 'track_io_timing';
SELECT assert_true(boot_val = '-1', 'log_min_duration_statement is disabled by default')
FROM pg_settings WHERE name = 'log_min_duration_statement';
SELECT assert_true(current_setting('pg_stat_statements.max') = '5000', 'pg_stat_statements.max defaults to 5000');

-- Turn on I/O timing so shared_blk_read_time and EXPLAIN BUFFERS get times.
SET track_io_timing = on;
SELECT assert_true(current_setting('track_io_timing') = 'on', 'track_io_timing is on for this session');

-- Start a clean window for this database only (in production, snapshot instead).
SELECT pg_stat_statements_reset(0::oid, oid, 0::bigint) FROM pg_database WHERE datname = current_database();

-- Workload. pg_sleep(0.002) stands in for the per-call work of a cheap
-- lookup so the totals are deterministic on any machine.
-- 500 top-level lookups, each with a different literal id:
SELECT format('SELECT status, pg_sleep(0.002) FROM obs_orders WHERE id = %s', g) FROM generate_series(1, 500) AS g \gexec
-- 3 runs of an expensive report:
SELECT customer_id, sum(amount) FROM obs_orders GROUP BY customer_id ORDER BY 2 DESC LIMIT 10;
SELECT customer_id, sum(amount) FROM obs_orders GROUP BY customer_id ORDER BY 2 DESC LIMIT 10;
SELECT customer_id, sum(amount) FROM obs_orders GROUP BY customer_id ORDER BY 2 DESC LIMIT 10;

-- Rank by total_exec_time: the share of server time each query takes.
SELECT queryid, calls, round(total_exec_time::numeric, 1) AS total_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms, left(query, 70) AS query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC
LIMIT 10;

SELECT assert_true(
  (SELECT query FROM pg_stat_statements
   WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
     AND query LIKE '%FROM obs_orders%'
   ORDER BY total_exec_time DESC LIMIT 1) LIKE '%WHERE id = $%',
  'the 500-call lookup costs the most in total, ahead of the 3-call report');

-- Normalization: 500 different literals became one entry with $n.
SELECT assert_true(count(*) = 1 AND sum(calls) = 500, 'the 500 lookups share one normalized entry')
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND query LIKE '%FROM obs_orders WHERE id = %';
SELECT assert_true(query NOT LIKE '%0.002%' AND query NOT LIKE '%id = 1%', 'no literal survives in the stored text')
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND query LIKE '%FROM obs_orders WHERE id = %';

-- Literals leak back when entries are evicted: watch dealloc.
SELECT dealloc, stats_reset FROM pg_stat_statements_info;
SELECT assert_true(count(*) = 1, 'pg_stat_statements_info reports dealloc') FROM pg_stat_statements_info;

-- auto_explain, sampled, with ANALYZE but without per-node timing.
-- (In production put it in shared_preload_libraries or session_preload_libraries.)
LOAD 'auto_explain';
SET auto_explain.log_min_duration = '500ms';
SET auto_explain.log_analyze = on;
SET auto_explain.log_timing = off;
SET auto_explain.log_buffers = on;
SET auto_explain.sample_rate = 0.1;
SELECT assert_true(current_setting('auto_explain.sample_rate')::float8 = 0.1, 'auto_explain explains one statement in ten');
RESET auto_explain.log_min_duration;

-- EXPLAIN (ANALYZE, BUFFERS) on a read: it runs, but changes nothing.
DO $$
DECLARE
  plan jsonb;
BEGIN
  EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT status FROM obs_orders WHERE customer_id = 42' INTO plan;
  PERFORM assert_true(plan->0->'Plan' ? 'Shared Hit Blocks', 'BUFFERS reports shared hits');
  PERFORM assert_true((plan->0->'Plan'->>'Actual Rows')::numeric > 0, 'ANALYZE reports actual rows');
END
$$;

-- EXPLAIN ANALYZE on a write: only inside BEGIN/ROLLBACK, in a sandbox.
SELECT last_value AS seq_before FROM obs_orders_id_seq \gset
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
INSERT INTO obs_orders (customer_id, amount, status) VALUES (1, 9.99, 'paid');
ROLLBACK;
SELECT assert_true(count(*) = 200000, 'the explained INSERT was rolled back') FROM obs_orders;
-- The sequence is not rolled back: nextval is never reclaimed.
SELECT assert_true(last_value = :seq_before + 1, 'ROLLBACK did not undo nextval') FROM obs_orders_id_seq;

-- Wait events: what active sessions are waiting on right now.
SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE state = 'active' AND pid <> pg_backend_pid()
GROUP BY 1, 2
ORDER BY 3 DESC;
SELECT assert_true(state = 'active' AND wait_event IS NULL, 'this session is on CPU, not waiting')
FROM pg_stat_activity WHERE pid = pg_backend_pid();

-- pg_stat_io exists from PG 16; PG 18 replaced op_bytes with *_bytes columns.
DO $$
DECLARE
  v int := current_setting('server_version_num')::int;
BEGIN
  IF v < 160000 THEN
    PERFORM assert_true(to_regclass('pg_catalog.pg_stat_io') IS NULL, 'PG 15 has no pg_stat_io');
    RETURN;
  END IF;
  PERFORM assert_true(EXISTS (SELECT 1 FROM pg_stat_io WHERE object = 'relation'), 'pg_stat_io has relation rows');
  IF v >= 180000 THEN
    PERFORM assert_true(EXISTS (SELECT 1 FROM pg_attribute
      WHERE attrelid = 'pg_catalog.pg_stat_io'::regclass AND attname = 'read_bytes'), 'PG 18 has read_bytes');
    PERFORM assert_true(NOT EXISTS (SELECT 1 FROM pg_attribute
      WHERE attrelid = 'pg_catalog.pg_stat_io'::regclass AND attname = 'op_bytes'), 'PG 18 dropped op_bytes');
  ELSE
    PERFORM assert_true(EXISTS (SELECT 1 FROM pg_attribute
      WHERE attrelid = 'pg_catalog.pg_stat_io'::regclass AND attname = 'op_bytes'), 'PG 16/17 have op_bytes');
  END IF;
END
$$;
