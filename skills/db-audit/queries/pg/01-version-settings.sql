-- Engine, version, role of the instance and the statistics window.
-- server_version_num decides which version-gated files to run
-- (12-vacuum-time-pg18.sql only on 180000 and above).
SELECT version() AS version,
       current_setting('server_version_num')::int AS server_version_num,
       pg_is_in_recovery() AS on_replica,
       pg_postmaster_start_time() AS server_started,
       now() - pg_postmaster_start_time() AS uptime,
       d.stats_reset AS database_stats_reset,
       now() - coalesce(d.stats_reset, pg_postmaster_start_time()) AS stats_window
FROM pg_stat_database d
WHERE d.datname = current_database();

-- Extensions the later files depend on (pg_stat_statements) or the skill may
-- suggest (hypopg, pgstattuple). Installing one is the user's decision.
SELECT extname, extversion
FROM pg_extension
ORDER BY extname;

-- Settings the findings refer to. Names absent from this version simply
-- return no row.
SELECT name, setting, unit, source, pending_restart
FROM pg_settings
WHERE name IN ('max_connections', 'superuser_reserved_connections', 'reserved_connections',
               'shared_buffers', 'effective_cache_size', 'work_mem', 'hash_mem_multiplier',
               'maintenance_work_mem', 'autovacuum_work_mem', 'random_page_cost',
               'effective_io_concurrency', 'io_method', 'max_wal_size', 'checkpoint_timeout',
               'autovacuum', 'autovacuum_max_workers', 'autovacuum_naptime',
               'autovacuum_vacuum_threshold', 'autovacuum_vacuum_scale_factor',
               'autovacuum_vacuum_max_threshold', 'autovacuum_vacuum_cost_limit',
               'autovacuum_vacuum_cost_delay', 'autovacuum_freeze_max_age',
               'statement_timeout', 'lock_timeout', 'idle_in_transaction_session_timeout',
               'transaction_timeout', 'idle_session_timeout', 'jit', 'default_statistics_target',
               'track_io_timing', 'track_activity_query_size', 'compute_query_id',
               'log_min_duration_statement', 'log_lock_waits', 'log_temp_files',
               'log_autovacuum_min_duration', 'shared_preload_libraries',
               'pg_stat_statements.max', 'pg_stat_statements.track', 'hot_standby_feedback')
ORDER BY name;
