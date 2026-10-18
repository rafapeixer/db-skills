-- Connections in use against the limit, and the high-water mark since start.
SELECT @@max_connections AS max_connections,
       @@max_user_connections AS max_user_connections,
       @@wait_timeout AS wait_timeout_s,
       @@thread_cache_size AS thread_cache_size;

SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN ('Threads_connected', 'Threads_running', 'Threads_created',
                        'Max_used_connections', 'Max_used_connections_time',
                        'Connections', 'Aborted_connects', 'Aborted_clients',
                        'Connection_errors_max_connections')
ORDER BY VARIABLE_NAME;

-- Who holds them: current connections per account.
SELECT USER AS user, HOST AS host, CURRENT_CONNECTIONS, TOTAL_CONNECTIONS
FROM performance_schema.accounts
WHERE USER IS NOT NULL
ORDER BY CURRENT_CONNECTIONS DESC
LIMIT 30;

-- And what they are doing.
SELECT USER AS user, DB AS db, COMMAND AS command, COUNT(*) AS connections
FROM performance_schema.processlist
GROUP BY USER, DB, COMMAND
ORDER BY COUNT(*) DESC
LIMIT 30;
