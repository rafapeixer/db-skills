-- Foreign keys whose referencing columns do not lead any valid, non-partial
-- index. Without one, every DELETE of a parent row (or update of its key)
-- scans the child table while holding its locks.
SELECT c.conrelid::regclass AS table_name,
       c.conname AS foreign_key,
       c.confrelid::regclass AS references_table,
       array_agg(a.attname ORDER BY x.n) AS fk_columns,
       pg_size_pretty(pg_relation_size(c.conrelid)) AS table_size,
       pg_relation_size(c.conrelid) AS table_bytes
FROM pg_constraint c
CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS x(attnum, n)
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum
WHERE c.contype = 'f'
  AND NOT EXISTS (
        SELECT 1
        FROM pg_index i
        WHERE i.indrelid = c.conrelid
          AND i.indisvalid
          AND i.indpred IS NULL
          AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] @> c.conkey)
GROUP BY c.conrelid, c.conname, c.confrelid
ORDER BY pg_relation_size(c.conrelid) DESC;
