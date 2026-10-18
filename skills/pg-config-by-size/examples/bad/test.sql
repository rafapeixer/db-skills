-- Bad: a global work_mem picked without multiplying it out, and a large
-- sort left at the default work_mem so it spills to disk.

CREATE TABLE events (
  id      bigint PRIMARY KEY,
  payload text NOT NULL
);
INSERT INTO events
SELECT g, md5(g::text) || md5((g * 7)::text)
FROM generate_series(1, 300000) AS g;
ANALYZE events;

CREATE FUNCTION sort_space_type(query text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  plan jsonb;
BEGIN
  EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON, TIMING OFF) ' || query INTO plan;
  RETURN jsonb_path_query_first(plan, '$.**."Sort Space Type"') #>> '{}';
END
$$;

-- MISTAKE: work_mem raised globally (here for the session; in production
-- in postgresql.conf or the parameter group) to fix one slow report.
-- Every sort and hash node of every connection may now use 256MB.
SET work_mem = '256MB';

CREATE TEMP TABLE budget AS
SELECT pg_size_bytes(current_setting('shared_buffers')) AS shared_buffers,
       current_setting('max_connections')::bigint AS max_connections,
       pg_size_bytes(current_setting('work_mem')) AS work_mem,
       2 AS nodes_per_query;

-- MISTAKE: 100 connections x 2 nodes x 256MB = 50GB of possible work
-- memory on a 16GB instance. Under load the kernel OOM killer ends a
-- backend and PostgreSQL restarts every session.
SELECT assert_true(
  shared_buffers + max_connections * nodes_per_query * work_mem
  > pg_size_bytes('16GB'),
  'global work_mem x max_connections x nodes exceeds a 16GB instance')
FROM budget;

RESET work_mem;

-- MISTAKE: the report runs at the default work_mem (4MB), so its sort
-- spills to temporary files (external merge) instead of sorting in memory.
SELECT assert_true(
  sort_space_type('SELECT id, payload FROM events ORDER BY payload') = 'Disk',
  'at the default work_mem the sort spills to disk (external merge)');
