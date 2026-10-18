-- Duplicate and left-prefix redundant indexes, with the index that makes each
-- one redundant. Structural, so it does not depend on the stats window.
-- sql_drop_index is reference text for the report; never run it. The
-- proposed migration makes the index INVISIBLE first.
SELECT table_schema,
       table_name,
       redundant_index_name,
       redundant_index_columns,
       redundant_index_non_unique,
       dominant_index_name,
       dominant_index_columns,
       dominant_index_non_unique,
       subpart_exists,
       sql_drop_index
FROM sys.schema_redundant_indexes
ORDER BY table_schema, table_name
LIMIT 100;
