-- Size, planner row estimate and activity of the tables the query touches.
-- reltuples is what the planner believes; n_live_tup is the running count.
-- A large gap, or an old last_analyze with many n_mod_since_analyze, points
-- to stale statistics. Same ARRAY[...] edit as 01-indexes-for-tables.sql.
WITH target AS (
  SELECT to_regclass(t) AS rel
  FROM unnest(ARRAY['public.replace_me']::text[]) AS t
)
SELECT c.oid::regclass AS table_name,
       c.relkind,
       c.reltuples::bigint AS planner_rows,
       c.relpages AS planner_pages,
       s.n_live_tup,
       s.n_dead_tup,
       s.n_mod_since_analyze,
       s.last_analyze,
       s.last_autoanalyze,
       s.seq_scan,
       s.idx_scan,
       pg_size_pretty(pg_relation_size(c.oid)) AS heap_size,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
       c.reloptions AS table_options
FROM target
JOIN pg_class c ON c.oid = target.rel
LEFT JOIN pg_stat_all_tables s ON s.relid = c.oid;
