-- Size and the optimizer's row estimate for the tables the query touches.
-- TABLE_ROWS is an InnoDB estimate. These values are cached for
-- information_schema_stats_expiry seconds. Same IN (...) edit as
-- 01-indexes-for-tables.sql.
SELECT TABLE_NAME AS table_name,
       ENGINE AS engine,
       TABLE_ROWS AS estimated_rows,
       AVG_ROW_LENGTH AS avg_row_bytes,
       ROUND(DATA_LENGTH / 1024 / 1024, 1) AS data_mb,
       ROUND(INDEX_LENGTH / 1024 / 1024, 1) AS index_mb,
       ROUND(DATA_FREE / 1024 / 1024, 1) AS free_mb,
       CREATE_OPTIONS AS create_options
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('replace_me');

-- Histograms present on those tables: type, buckets and when they were
-- built. The bucket values hold real data (possible PII) and are never
-- selected.
SELECT TABLE_NAME AS table_name,
       COLUMN_NAME AS column_name,
       HISTOGRAM ->> '$."histogram-type"' AS histogram_type,
       HISTOGRAM ->> '$."number-of-buckets-specified"' AS buckets,
       HISTOGRAM ->> '$."last-updated"' AS last_updated
FROM information_schema.COLUMN_STATISTICS
WHERE SCHEMA_NAME = DATABASE()
  AND TABLE_NAME IN ('replace_me');
