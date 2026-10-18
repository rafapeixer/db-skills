-- Top statements by total latency, grouped by digest. DIGEST_TEXT is the
-- normalized text (literals replaced by ?). QUERY_SAMPLE_TEXT holds a raw
-- sample with literals and is deliberately not selected.
-- Timers are in picoseconds: / 1e9 gives milliseconds.
SELECT SCHEMA_NAME AS db,
       DIGEST,
       COUNT_STAR AS calls,
       ROUND(SUM_TIMER_WAIT / 1e9, 1) AS total_ms,
       ROUND(AVG_TIMER_WAIT / 1e9, 2) AS mean_ms,
       ROUND(100 * SUM_TIMER_WAIT / NULLIF(SUM(SUM_TIMER_WAIT) OVER (), 0), 1) AS pct_of_total,
       ROUND(SUM_ROWS_EXAMINED / NULLIF(COUNT_STAR, 0)) AS rows_examined_avg,
       ROUND(SUM_ROWS_SENT / NULLIF(COUNT_STAR, 0)) AS rows_sent_avg,
       SUM_NO_INDEX_USED AS no_index_used,
       SUM_NO_GOOD_INDEX_USED AS no_good_index_used,
       SUM_CREATED_TMP_DISK_TABLES AS tmp_disk_tables,
       SUM_SORT_MERGE_PASSES AS sort_merge_passes,
       FIRST_SEEN,
       LAST_SEEN,
       LEFT(DIGEST_TEXT, 300) AS query_normalized
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST IS NOT NULL
  -- leave out monitoring queries, including this audit's own
  AND DIGEST_TEXT NOT LIKE '%`performance_schema`%'
  AND DIGEST_TEXT NOT LIKE '%`information_schema`%'
  AND DIGEST_TEXT NOT LIKE '%`sys` .%'
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;

-- Is the digest table complete? Digest_lost > 0 means the table filled up
-- and later statements were folded into the NULL-digest row.
SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'Performance_schema_digest_lost';

SELECT COUNT_STAR AS statements_without_digest_row,
       ROUND(SUM_TIMER_WAIT / 1e9, 1) AS total_ms
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST IS NULL;
