-- Sessions waiting on a lock, with the session blocking each one. Report only:
-- the fix belongs in the blocker's code or timeouts, never in ending it here.
-- pg_blocking_pids() is not free: run this once, do not poll it in a loop.
SELECT w.pid AS waiting_pid,
       w.usename AS waiting_user,
       w.application_name AS waiting_app,
       now() - w.query_start AS waiting_for,
       w.wait_event_type,
       w.wait_event,
       b.pid AS blocking_pid,
       b.usename AS blocking_user,
       b.application_name AS blocking_app,
       b.state AS blocking_state,
       now() - b.xact_start AS blocking_xact_age,
       left(regexp_replace(regexp_replace(w.query, $re$'(?:[^']|'')*'$re$, '?', 'g'),
                           $re$(?<![$\w])\d+(?:\.\d+)?$re$, '?', 'g'), 120) AS waiting_query_redacted,
       left(regexp_replace(regexp_replace(b.query, $re$'(?:[^']|'')*'$re$, '?', 'g'),
                           $re$(?<![$\w])\d+(?:\.\d+)?$re$, '?', 'g'), 120) AS blocking_query_redacted
FROM pg_stat_activity w
CROSS JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS bp(pid)
JOIN pg_stat_activity b ON b.pid = bp.pid
WHERE w.wait_event_type = 'Lock'
ORDER BY w.query_start;

-- Ungranted locks by type and mode.
SELECT locktype, mode, count(*) AS waiting
FROM pg_locks
WHERE NOT granted
GROUP BY locktype, mode
ORDER BY count(*) DESC;
