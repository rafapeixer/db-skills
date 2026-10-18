-- Indexes with no recorded use since server start (primary keys excluded by
-- the sys view). Counters are per instance and reset on restart: an index
-- unused on the source may serve reads on a replica. Check every instance,
-- and do not propose a change when Uptime is shorter than a business cycle.
-- Only tables this account has a privilege on are visible.
SELECT u.object_schema AS table_schema,
       u.object_name AS table_name,
       u.index_name
FROM sys.schema_unused_indexes u
WHERE u.object_schema NOT IN ('mysql', 'performance_schema', 'sys', 'information_schema')
ORDER BY u.object_schema, u.object_name, u.index_name
LIMIT 100;

-- Stats window for the list above, in seconds.
SELECT VARIABLE_VALUE AS uptime_seconds
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'Uptime';
