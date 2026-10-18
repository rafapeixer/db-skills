-- Exports the standard PostgreSQL statistics views as CSV, the way a DBA
-- would hand them over. Nothing here is specific to db-skills.
\pset footer off
\o /export/pg_stat_statements.csv
COPY (SELECT queryid, calls, round(total_exec_time::numeric, 1) AS total_exec_time_ms,
             round(mean_exec_time::numeric, 3) AS mean_exec_time_ms, rows,
             shared_blks_hit, shared_blks_read, left(regexp_replace(query, '\s+', ' ', 'g'), 300) AS query
      FROM pg_stat_statements
      WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
        AND query NOT ILIKE '%pg_stat%' AND query NOT ILIKE 'COPY%' AND query NOT ILIKE 'DO %' AND query NOT ILIKE 'SET %'
      ORDER BY total_exec_time DESC LIMIT 40) TO STDOUT WITH CSV HEADER;
\o /export/indexes.csv
COPY (SELECT s.schemaname, s.relname AS table_name, s.indexrelname AS index_name, s.idx_scan,
             pg_relation_size(s.indexrelid) AS size_bytes, pg_get_indexdef(s.indexrelid) AS definition
      FROM pg_stat_user_indexes s ORDER BY s.relname, s.indexrelname) TO STDOUT WITH CSV HEADER;
\o /export/tables.csv
COPY (SELECT relname AS table_name, n_live_tup, n_dead_tup, seq_scan, seq_tup_read, idx_scan,
             n_tup_upd, n_tup_hot_upd, last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
             (SELECT reloptions FROM pg_class c WHERE c.oid = t.relid) AS reloptions,
             pg_total_relation_size(relid) AS total_size_bytes
      FROM pg_stat_user_tables t ORDER BY relname) TO STDOUT WITH CSV HEADER;
\o /export/activity.csv
COPY (SELECT pid, usename, application_name, state, backend_type,
             date_trunc('second', now() - xact_start) AS xact_age,
             date_trunc('second', now() - state_change) AS state_age,
             wait_event_type, wait_event, left(query, 120) AS last_query
      FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()
      ORDER BY xact_start NULLS LAST) TO STDOUT WITH CSV HEADER;
\o /export/settings.csv
COPY (SELECT name, setting, unit, source FROM pg_settings
      WHERE name IN ('max_connections', 'superuser_reserved_connections', 'reserved_connections',
                     'shared_buffers', 'work_mem', 'maintenance_work_mem', 'effective_cache_size',
                     'idle_in_transaction_session_timeout', 'statement_timeout', 'lock_timeout',
                     'autovacuum', 'server_version')
      ORDER BY name) TO STDOUT WITH CSV HEADER;
\o
