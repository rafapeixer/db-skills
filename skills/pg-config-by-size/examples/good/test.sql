-- Good: size memory from the instance, keep work_mem small globally and
-- raise it with SET LOCAL for the one query that needs it.

CREATE TABLE events (
  id      bigint PRIMARY KEY,
  payload text NOT NULL
);
INSERT INTO events
SELECT g, md5(g::text) || md5((g * 7)::text)
FROM generate_series(1, 300000) AS g;
ANALYZE events;

-- sort_space_type runs the query under EXPLAIN ANALYZE (scratch database
-- only: ANALYZE executes it) and returns where the sort ran: Memory or Disk.
CREATE FUNCTION sort_space_type(query text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  plan jsonb;
BEGIN
  EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON, TIMING OFF) ' || query INTO plan;
  RETURN jsonb_path_query_first(plan, '$.**."Sort Space Type"') #>> '{}';
END
$$;

SELECT current_setting('work_mem') AS work_mem_before \gset

-- 1. One reporting query gets more memory, only inside its transaction.
BEGIN;
SET LOCAL work_mem = '128MB';
SELECT assert_true(
  sort_space_type('SELECT id, payload FROM events ORDER BY payload') = 'Memory',
  'with SET LOCAL work_mem = 128MB the sort runs in memory (quicksort)');
COMMIT;

-- 2. After COMMIT the session is back to the global value.
SELECT assert_true(
  current_setting('work_mem') = :'work_mem_before',
  'SET LOCAL ends with the transaction; the global work_mem is untouched');

-- 3. Memory budget from the live settings: shared memory plus the worst
-- case of every connection running a query with 2 sort/hash nodes, plus
-- autovacuum workers each using maintenance_work_mem.
CREATE TEMP TABLE budget AS
SELECT pg_size_bytes(current_setting('shared_buffers')) AS shared_buffers,
       current_setting('max_connections')::bigint AS max_connections,
       pg_size_bytes(current_setting('work_mem')) AS work_mem,
       current_setting('hash_mem_multiplier')::numeric AS hash_mem_multiplier,
       2 AS nodes_per_query,
       pg_size_bytes(current_setting('maintenance_work_mem')) AS maintenance_work_mem,
       current_setting('autovacuum_max_workers')::bigint AS autovacuum_workers;

SELECT pg_size_pretty(shared_buffers
  + max_connections * nodes_per_query * work_mem * hash_mem_multiplier
  + autovacuum_workers * maintenance_work_mem) AS worst_case
FROM budget;

-- The defaults (128MB, 100 connections, 4MB) fit a 16GB instance with room
-- for the OS page cache that effective_cache_size describes.
SELECT assert_true(
  shared_buffers
  + max_connections * nodes_per_query * work_mem * hash_mem_multiplier
  + autovacuum_workers * maintenance_work_mem
  < pg_size_bytes('16GB') * 0.75,
  'worst-case memory budget fits in 75% of a 16GB instance')
FROM budget;

-- 4. effective_cache_size allocates nothing: it is a planner hint, and a
-- session can change it without touching shared memory.
SELECT assert_true(
  (SELECT context FROM pg_settings WHERE name = 'effective_cache_size') = 'user',
  'effective_cache_size is a per-session planner setting');
SELECT assert_true(
  (SELECT context FROM pg_settings WHERE name = 'shared_buffers') = 'postmaster',
  'shared_buffers needs a restart (static parameter on RDS)');

-- 5. Async I/O defaults, gated by major version.
DO $$
BEGIN
  IF current_setting('server_version_num')::int >= 180000 THEN
    PERFORM assert_true(current_setting('io_method') = 'worker',
      'PG 18 default io_method is worker');
    PERFORM assert_true(
      (SELECT context FROM pg_settings WHERE name = 'io_method') = 'postmaster',
      'io_method can only be set at server start');
    PERFORM assert_true(current_setting('effective_io_concurrency') = '16',
      'PG 18 default effective_io_concurrency is 16');
  ELSE
    PERFORM assert_true(
      NOT EXISTS (SELECT 1 FROM pg_settings WHERE name = 'io_method'),
      'io_method does not exist before PG 18');
  END IF;
END
$$;
