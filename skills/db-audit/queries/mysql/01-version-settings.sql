-- Engine, version, role of the instance and the statistics window.
-- Every performance_schema and sys counter used later is per instance and
-- counts from server start: Uptime is the stats window.
SELECT VERSION() AS version,
       @@version_comment AS distribution,
       @@global.read_only AS read_only,
       @@global.super_read_only AS super_read_only,
       @@performance_schema AS performance_schema_on;

SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN ('Uptime', 'Uptime_since_flush_status');

-- Replication channels this server applies from (empty on a source).
SELECT CHANNEL_NAME, SERVICE_STATE, SOURCE_UUID
FROM performance_schema.replication_connection_status;

-- Settings the findings refer to. Names absent from this version simply
-- return no row.
SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_variables
WHERE VARIABLE_NAME IN ('max_connections', 'max_user_connections', 'wait_timeout',
                        'innodb_buffer_pool_size', 'innodb_buffer_pool_instances',
                        'innodb_dedicated_server', 'innodb_redo_log_capacity',
                        'innodb_flush_log_at_trx_commit', 'sync_binlog', 'binlog_format',
                        'innodb_io_capacity', 'innodb_lock_wait_timeout', 'lock_wait_timeout',
                        'innodb_purge_threads', 'innodb_max_purge_lag', 'innodb_adaptive_hash_index',
                        'transaction_isolation', 'tmp_table_size', 'max_heap_table_size',
                        'temptable_max_ram', 'sort_buffer_size', 'join_buffer_size',
                        'slow_query_log', 'long_query_time', 'log_slow_extra',
                        'performance_schema_digests_size', 'max_digest_length',
                        'information_schema_stats_expiry', 'sql_mode')
ORDER BY VARIABLE_NAME;
