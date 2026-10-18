-- How the query behaves in production, by digest. DIGEST_TEXT is normalized
-- (literals replaced by ?); QUERY_SAMPLE_TEXT is raw and never selected.
-- The only edit allowed: replace the text inside the LIKE pattern with a
-- distinctive fragment of the user's query (a table or column name, not a
-- value). Timers are picoseconds: / 1e9 gives milliseconds.
SELECT SCHEMA_NAME AS db,
       DIGEST,
       COUNT_STAR AS calls,
       ROUND(AVG_TIMER_WAIT / 1e9, 2) AS mean_ms,
       ROUND(MAX_TIMER_WAIT / 1e9, 2) AS max_ms,
       ROUND(SUM_TIMER_WAIT / 1e9, 1) AS total_ms,
       ROUND(SUM_ROWS_EXAMINED / NULLIF(COUNT_STAR, 0)) AS rows_examined_avg,
       ROUND(SUM_ROWS_SENT / NULLIF(COUNT_STAR, 0)) AS rows_sent_avg,
       SUM_NO_INDEX_USED AS no_index_used,
       SUM_CREATED_TMP_DISK_TABLES AS tmp_disk_tables,
       SUM_SORT_MERGE_PASSES AS sort_merge_passes,
       LEFT(DIGEST_TEXT, 300) AS query_normalized
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT LIKE CONCAT('%', 'replace_me', '%')
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;
