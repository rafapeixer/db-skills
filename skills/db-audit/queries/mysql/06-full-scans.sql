-- Tables read without an index: rows fetched by full scans since start
-- (performance_schema records them under INDEX_NAME IS NULL).
SELECT OBJECT_SCHEMA AS table_schema,
       OBJECT_NAME AS table_name,
       COUNT_READ AS rows_read_without_index,
       ROUND(SUM_TIMER_READ / 1e9, 1) AS read_ms
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE INDEX_NAME IS NULL
  AND OBJECT_SCHEMA NOT IN ('mysql', 'performance_schema', 'sys', 'information_schema')
  AND COUNT_READ > 0
ORDER BY COUNT_READ DESC
LIMIT 20;

-- Statements that ran full scans, by digest (normalized text).
SELECT db,
       exec_count,
       ROUND(total_latency / 1e9, 1) AS total_ms,
       no_index_used_count,
       no_good_index_used_count,
       no_index_used_pct,
       rows_examined_avg,
       rows_sent_avg,
       digest,
       LEFT(query, 300) AS query_normalized
FROM sys.x$statements_with_full_table_scans
WHERE query NOT LIKE '%`performance_schema`%'
  AND query NOT LIKE '%`information_schema`%'
  AND query NOT LIKE '%`sys` .%'
ORDER BY total_latency DESC
LIMIT 20;
