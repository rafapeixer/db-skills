-- Planner statistics per column: how selective a filter on it is and how
-- well its order matches the table order. most_common_vals and
-- histogram_bounds hold real data values (possible PII) and are never
-- selected. pg_stats shows a column only if the role may read it.
-- Same ARRAY[...] edit as 01-indexes-for-tables.sql.
WITH target AS (
  SELECT to_regclass(t) AS rel
  FROM unnest(ARRAY['public.replace_me']::text[]) AS t
)
SELECT st.schemaname,
       st.tablename,
       st.attname AS column_name,
       st.null_frac,
       st.n_distinct,
       st.correlation,
       st.avg_width,
       a.attstattarget AS column_statistics_target
FROM target
JOIN pg_class c ON c.oid = target.rel
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_stats st ON st.schemaname = n.nspname AND st.tablename = c.relname
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = st.attname
ORDER BY st.tablename, st.attname;
