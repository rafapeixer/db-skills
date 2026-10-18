-- The connection limit, the per-account cap and the high-water mark since
-- server start. Max_used_connections is the peak MySQL itself observed;
-- Connection_errors_max_connections counts clients refused at the limit.
SELECT @@max_connections AS max_connections,
       @@max_user_connections AS max_user_connections,
       @@wait_timeout AS wait_timeout_s,
       @@interactive_timeout AS interactive_timeout_s,
       @@thread_cache_size AS thread_cache_size,
       @@global.read_only AS read_only,
       @@global.super_read_only AS super_read_only;

SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN ('Threads_connected', 'Threads_running', 'Max_used_connections',
                        'Max_used_connections_time', 'Connection_errors_max_connections',
                        'Aborted_connects', 'Aborted_clients', 'Connections', 'Uptime')
ORDER BY VARIABLE_NAME;
