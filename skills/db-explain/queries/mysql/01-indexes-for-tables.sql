-- Indexes on the tables the user's query touches, columns in index order,
-- with usage since server start. The only edit allowed before running:
-- replace the names in the IN (...) list with the tables of the query (in
-- the current database). A name that does not exist just returns no rows.
-- information_schema shows only tables this account has a privilege on.
SELECT s.TABLE_NAME AS table_name,
       s.INDEX_NAME AS index_name,
       GROUP_CONCAT(COALESCE(s.COLUMN_NAME, CONCAT('(', s.EXPRESSION, ')'))
                    ORDER BY s.SEQ_IN_INDEX SEPARATOR ', ') AS columns_in_order,
       MIN(s.NON_UNIQUE) = 0 AS is_unique,
       MAX(s.IS_VISIBLE) AS is_visible,
       MAX(s.CARDINALITY) AS cardinality_estimate,
       MAX(s.SUB_PART) AS has_prefix_part,
       MAX(s.INDEX_TYPE) AS index_type,
       MAX(u.COUNT_READ) AS rows_read_through_index
FROM information_schema.STATISTICS s
LEFT JOIN performance_schema.table_io_waits_summary_by_index_usage u
       ON u.OBJECT_SCHEMA = s.TABLE_SCHEMA
      AND u.OBJECT_NAME = s.TABLE_NAME
      AND u.INDEX_NAME = s.INDEX_NAME
WHERE s.TABLE_SCHEMA = DATABASE()
  AND s.TABLE_NAME IN ('replace_me')
GROUP BY s.TABLE_NAME, s.INDEX_NAME
ORDER BY s.TABLE_NAME, s.INDEX_NAME;
