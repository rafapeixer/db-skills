-- Connections open now per account, and since server start.
SELECT USER AS user,
       HOST AS host,
       CURRENT_CONNECTIONS AS current_connections,
       TOTAL_CONNECTIONS AS total_connections
FROM performance_schema.accounts
WHERE USER IS NOT NULL
ORDER BY CURRENT_CONNECTIONS DESC
LIMIT 50;

-- What they are doing: Sleep threads are pool slots held open. Client hosts
-- are counted, not listed.
SELECT USER AS user,
       DB AS db,
       COMMAND AS command,
       COUNT(*) AS connections,
       COUNT(DISTINCT SUBSTRING_INDEX(HOST, ':', 1)) AS client_hosts,
       MAX(TIME) AS longest_in_state_s
FROM performance_schema.processlist
GROUP BY USER, DB, COMMAND
ORDER BY COUNT(*) DESC
LIMIT 50;
