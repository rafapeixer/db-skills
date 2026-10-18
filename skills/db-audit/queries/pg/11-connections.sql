-- Connections in use against the limit. reserved_connections exists on PG 16+
-- only; current_setting(..., true) returns NULL instead of failing on 15.
SELECT count(*) FILTER (WHERE backend_type = 'client backend') AS client_connections,
       count(*) FILTER (WHERE backend_type = 'client backend' AND state = 'active') AS active,
       count(*) FILTER (WHERE backend_type = 'client backend' AND state = 'idle') AS idle,
       count(*) FILTER (WHERE backend_type = 'client backend' AND state LIKE 'idle in transaction%') AS idle_in_transaction,
       current_setting('max_connections')::int AS max_connections,
       current_setting('superuser_reserved_connections')::int AS superuser_reserved,
       current_setting('reserved_connections', true)::int AS reserved_connections,
       round(100.0 * count(*) FILTER (WHERE backend_type = 'client backend')
             / current_setting('max_connections')::int, 1) AS pct_of_max
FROM pg_stat_activity;

-- Who holds them.
SELECT usename, application_name, datname, state, count(*) AS connections
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY usename, application_name, datname, state
ORDER BY count(*) DESC
LIMIT 30;
