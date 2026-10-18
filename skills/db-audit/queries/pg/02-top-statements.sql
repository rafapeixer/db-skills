-- Top statements by total execution time in this database.
-- Needs pg_stat_statements (see 01-version-settings.sql); skip this file if
-- the extension is not installed and report that as a finding instead.
-- Query texts are normalized ($1, $2), but texts can still hold literals
-- (see the dealloc check below), so literals are redacted here as well.
-- I/O timing and stats_since are read through to_jsonb so the same file runs
-- on PG 15/16 (blk_read_time) and 17+ (shared_blk_read_time, stats_since).
SELECT s.queryid,
       s.calls,
       round(s.total_exec_time::numeric, 1) AS total_ms,
       round(s.mean_exec_time::numeric, 2) AS mean_ms,
       round((100 * s.total_exec_time / nullif(sum(s.total_exec_time) OVER (), 0))::numeric, 1) AS pct_of_total,
       s.rows,
       round(s.rows::numeric / nullif(s.calls, 0), 1) AS rows_per_call,
       round(100.0 * s.shared_blks_hit / nullif(s.shared_blks_hit + s.shared_blks_read, 0), 1) AS hit_pct,
       s.temp_blks_written,
       coalesce((to_jsonb(s) ->> 'shared_blk_read_time')::float8,
                (to_jsonb(s) ->> 'blk_read_time')::float8) AS read_time_ms,
       (to_jsonb(s) ->> 'stats_since')::timestamptz AS stats_since,
       left(regexp_replace(
              regexp_replace(
                regexp_replace(s.query, $re$'(?:[^']|'')*'$re$, '?', 'g'),
                $re$(?<![$\w])\d+(?:\.\d+)?$re$, '?', 'g'),
              '\s+', ' ', 'g'), 300) AS query_redacted
FROM pg_stat_statements s
WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND s.userid <> (SELECT oid FROM pg_roles WHERE rolname = current_user) -- not the audit's own
ORDER BY s.total_exec_time DESC
LIMIT 20;

-- Slowest on average among statements called often enough to matter.
SELECT s.queryid,
       s.calls,
       round(s.mean_exec_time::numeric, 2) AS mean_ms,
       round(s.total_exec_time::numeric, 1) AS total_ms,
       left(regexp_replace(
              regexp_replace(
                regexp_replace(s.query, $re$'(?:[^']|'')*'$re$, '?', 'g'),
                $re$(?<![$\w])\d+(?:\.\d+)?$re$, '?', 'g'),
              '\s+', ' ', 'g'), 300) AS query_redacted
FROM pg_stat_statements s
WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND s.userid <> (SELECT oid FROM pg_roles WHERE rolname = current_user)
  AND s.calls >= 50
ORDER BY s.mean_exec_time DESC
LIMIT 10;

-- Window of the data and literal-leak risk: dealloc > 0 means entries were
-- evicted, and the docs warn texts may then appear with literal values.
SELECT dealloc,
       stats_reset,
       current_setting('pg_stat_statements.max', true) AS max_entries
FROM pg_stat_statements_info;
