-- Exact duplicates: same table, access method, key columns, operator classes,
-- collations, expressions and predicate. Keep one; the others only cost writes.
SELECT i.indrelid::regclass AS table_name,
       array_agg(i.indexrelid::regclass ORDER BY i.indexrelid) AS duplicate_indexes,
       pg_size_pretty(sum(pg_relation_size(i.indexrelid))) AS total_size
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
GROUP BY i.indrelid, c.relam, i.indkey::text, i.indclass::text, i.indcollation::text,
         coalesce(i.indexprs::text, ''), coalesce(i.indpred::text, '')
HAVING count(*) > 1;

-- Prefix-redundant: a plain, non-unique index whose key columns are the
-- leading key columns of another index of the same type on the same table.
-- The wider index serves the same lookups, at a slightly larger read cost.
SELECT a.indrelid::regclass AS table_name,
       a.indexrelid::regclass AS redundant_index,
       pg_get_indexdef(a.indexrelid) AS redundant_definition,
       b.indexrelid::regclass AS covered_by,
       pg_get_indexdef(b.indexrelid) AS covering_definition,
       pg_size_pretty(pg_relation_size(a.indexrelid)) AS redundant_size
FROM pg_index a
JOIN pg_class ac ON ac.oid = a.indexrelid
JOIN pg_namespace an ON an.oid = ac.relnamespace
JOIN pg_index b ON b.indrelid = a.indrelid AND b.indexrelid <> a.indexrelid
JOIN pg_class bc ON bc.oid = b.indexrelid
WHERE an.nspname NOT IN ('pg_catalog', 'information_schema')
  AND an.nspname NOT LIKE 'pg_toast%'
  AND ac.relam = bc.relam
  AND b.indisvalid
  AND NOT a.indisunique
  AND NOT a.indisprimary
  AND a.indexprs IS NULL AND b.indexprs IS NULL
  AND a.indpred IS NULL AND b.indpred IS NULL
  AND a.indnatts = a.indnkeyatts
  AND a.indnkeyatts < b.indnkeyatts
  AND (b.indkey::int2[])[0:a.indnkeyatts - 1] = (a.indkey::int2[])[0:a.indnkeyatts - 1]
  AND (b.indclass::oid[])[0:a.indnkeyatts - 1] = (a.indclass::oid[])[0:a.indnkeyatts - 1]
  AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = a.indexrelid)
ORDER BY pg_relation_size(a.indexrelid) DESC;

-- Invalid indexes: failed CREATE INDEX CONCURRENTLY builds. Ignored by the
-- planner but still updated on every write.
SELECT i.indexrelid::regclass AS invalid_index,
       i.indrelid::regclass AS table_name,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size
FROM pg_index i
WHERE NOT i.indisvalid;
