-- Long-running and idle-in-transaction sessions. Both hold a snapshot that
-- stops vacuum from removing dead rows, and an idle transaction keeps its
-- locks. pg_stat_activity texts are raw, with literals, so they are redacted.
SELECT a.pid,
       a.usename,
       a.application_name,
       a.state,
       a.wait_event_type,
       a.wait_event,
       now() - a.xact_start AS xact_age,
       now() - a.query_start AS query_age,
       now() - a.state_change AS in_state_for,
       age(a.backend_xmin) AS xmin_age,
       left(regexp_replace(
              regexp_replace(
                regexp_replace(a.query, $re$'(?:[^']|'')*'$re$, '?', 'g'),
                $re$(?<![$\w])\d+(?:\.\d+)?$re$, '?', 'g'),
              '\s+', ' ', 'g'), 200) AS query_redacted
FROM pg_stat_activity a
WHERE a.backend_type = 'client backend'
  AND a.pid <> pg_backend_pid()
  AND (a.state LIKE 'idle in transaction%'
       OR (a.state = 'active' AND now() - a.query_start > interval '1 minute')
       OR now() - a.xact_start > interval '5 minutes')
ORDER BY a.xact_start NULLS LAST
LIMIT 50;

-- Other holders of the xmin horizon: replication slots and prepared
-- transactions. Retained WAL can only be computed on a primary.
SELECT s.slot_name,
       s.slot_type,
       s.active,
       age(s.xmin) AS xmin_age,
       age(s.catalog_xmin) AS catalog_xmin_age,
       s.wal_status,
       CASE WHEN pg_is_in_recovery() THEN NULL
            ELSE pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn))
       END AS retained_wal
FROM pg_replication_slots s;

SELECT gid, prepared, owner, database, age(transaction) AS xid_age
FROM pg_prepared_xacts;
