-- How the query behaves in production, from pg_stat_statements. Skip this
-- file when the extension is not installed.
-- The only edit allowed: replace the text inside the ILIKE pattern with a
-- distinctive fragment of the user's query (a table and column name, not a
-- value). Texts are redacted the same way as in db-audit.
SELECT s.queryid,
       s.calls,
       round(s.mean_exec_time::numeric, 2) AS mean_ms,
       round(s.stddev_exec_time::numeric, 2) AS stddev_ms,
       round(s.max_exec_time::numeric, 2) AS max_ms,
       round(s.total_exec_time::numeric, 1) AS total_ms,
       round(s.rows::numeric / nullif(s.calls, 0), 1) AS rows_per_call,
       round(100.0 * s.shared_blks_hit / nullif(s.shared_blks_hit + s.shared_blks_read, 0), 1) AS hit_pct,
       s.temp_blks_written,
       left(regexp_replace(
              regexp_replace(
                regexp_replace(s.query, $re$'(?:[^']|'')*'$re$, '?', 'g'),
                $re$(?<![$\w])\d+(?:\.\d+)?$re$, '?', 'g'),
              '\s+', ' ', 'g'), 300) AS query_redacted
FROM pg_stat_statements s
WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND s.query ILIKE '%' || 'replace_me' || '%'
ORDER BY s.total_exec_time DESC
LIMIT 10;
