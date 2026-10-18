-- PG 18+ only: cumulative time spent vacuuming and analyzing each table
-- (columns added in PostgreSQL 18). The skill runs it only when
-- server_version_num >= 180000. The columns are read through to_jsonb, so on
-- older versions the file still runs and returns NULLs instead of failing.
SELECT t.schemaname,
       t.relname AS table_name,
       (to_jsonb(t) ->> 'total_vacuum_time')::float8 AS total_vacuum_ms,
       (to_jsonb(t) ->> 'total_autovacuum_time')::float8 AS total_autovacuum_ms,
       (to_jsonb(t) ->> 'total_analyze_time')::float8 AS total_analyze_ms,
       (to_jsonb(t) ->> 'total_autoanalyze_time')::float8 AS total_autoanalyze_ms,
       t.autovacuum_count,
       t.n_dead_tup
FROM pg_stat_user_tables t
ORDER BY coalesce((to_jsonb(t) ->> 'total_autovacuum_time')::float8, 0) DESC
LIMIT 20;
