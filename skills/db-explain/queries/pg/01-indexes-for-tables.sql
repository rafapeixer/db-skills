-- Indexes on the tables the user's query touches, with their usage.
-- The only edit allowed before running: replace the names in the ARRAY[...]
-- literal with the schema-qualified tables of the query. to_regclass()
-- returns NULL for a name that does not exist, so a typo gives no rows
-- instead of an error.
WITH target AS (
  SELECT to_regclass(t) AS rel
  FROM unnest(ARRAY['public.replace_me']::text[]) AS t
)
SELECT i.indrelid::regclass AS table_name,
       c.relname AS index_name,
       pg_get_indexdef(i.indexrelid) AS definition,
       i.indisunique AS is_unique,
       i.indisvalid AS is_valid,
       i.indnkeyatts AS key_columns,
       i.indnatts - i.indnkeyatts AS include_columns,
       i.indpred IS NOT NULL AS is_partial,
       s.idx_scan,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size
FROM target
JOIN pg_index i ON i.indrelid = target.rel
JOIN pg_class c ON c.oid = i.indexrelid
LEFT JOIN pg_stat_all_indexes s ON s.indexrelid = i.indexrelid
ORDER BY i.indrelid::regclass::text, c.relname;
