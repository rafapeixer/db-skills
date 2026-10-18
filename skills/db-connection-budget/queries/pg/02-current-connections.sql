-- Connections open now, per user and application, with their state. Idle
-- connections are pool slots held open; idle in transaction ones are slots
-- that also hold a snapshot and locks. A snapshot, not a peak: Postgres keeps
-- no high-water mark, so ask the user for the peak from their monitoring.
SELECT usename,
       application_name,
       datname,
       count(*) AS connections,
       count(*) FILTER (WHERE state = 'active') AS active,
       count(*) FILTER (WHERE state = 'idle') AS idle,
       count(*) FILTER (WHERE state LIKE 'idle in transaction%') AS idle_in_transaction,
       count(DISTINCT client_addr) AS client_hosts,
       min(backend_start) AS oldest_connection,
       max(backend_start) AS newest_connection
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY usename, application_name, datname
ORDER BY count(*) DESC
LIMIT 50;

-- Totals against the limit.
SELECT count(*) AS client_connections,
       count(*) FILTER (WHERE state = 'active') AS active,
       current_setting('max_connections')::int AS max_connections,
       round(100.0 * count(*) / current_setting('max_connections')::int, 1) AS pct_of_max
FROM pg_stat_activity
WHERE backend_type = 'client backend';

-- Every database on the server shares the same max_connections.
SELECT datname, numbackends
FROM pg_stat_database
WHERE datname IS NOT NULL
ORDER BY numbackends DESC;
