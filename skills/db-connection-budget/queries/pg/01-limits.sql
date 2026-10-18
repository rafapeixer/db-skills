-- The connection limit and the slots ordinary roles cannot use.
-- superuser_reserved_connections are kept for superusers; on PG 16+,
-- reserved_connections are kept for members of pg_use_reserved_connections.
-- current_setting(..., true) returns NULL on 15, where the setting does not
-- exist. Background workers, autovacuum workers and WAL senders have their
-- own limits and do not use these slots.
SELECT current_setting('max_connections')::int AS max_connections,
       current_setting('superuser_reserved_connections')::int AS superuser_reserved,
       coalesce(current_setting('reserved_connections', true)::int, 0) AS reserved_connections,
       current_setting('max_connections')::int
         - current_setting('superuser_reserved_connections')::int
         - coalesce(current_setting('reserved_connections', true)::int, 0) AS slots_for_ordinary_roles,
       current_setting('autovacuum_max_workers')::int AS autovacuum_max_workers,
       current_setting('max_wal_senders')::int AS max_wal_senders,
       current_setting('max_worker_processes')::int AS max_worker_processes,
       current_setting('server_version_num')::int AS server_version_num,
       pg_is_in_recovery() AS on_replica;

-- Per-role and per-database caps already in place (-1 means no cap).
SELECT 'role' AS scope, rolname AS name, rolconnlimit AS connection_limit
FROM pg_roles
WHERE rolcanlogin AND rolconnlimit <> -1
UNION ALL
SELECT 'database', datname, datconnlimit
FROM pg_database
WHERE datconnlimit <> -1
ORDER BY 1, 2;

-- Memory settings that scale with the number of connections.
SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('shared_buffers', 'work_mem', 'hash_mem_multiplier', 'maintenance_work_mem',
               'idle_in_transaction_session_timeout', 'idle_session_timeout')
ORDER BY name;
