-- InnoDB row lock waits, with the blocking transaction. Report only: the
-- sys view also offers statements to end the blocker; they are not selected
-- and must never be run by the agent. Query texts are redacted.
SELECT wait_started,
       wait_age_secs,
       locked_table,
       locked_index,
       locked_type,
       waiting_pid,
       waiting_trx_age,
       waiting_lock_mode,
       blocking_pid,
       blocking_trx_age,
       blocking_lock_mode,
       blocking_trx_rows_locked,
       LEFT(REGEXP_REPLACE(REGEXP_REPLACE(waiting_query, "'[^']*'", "?"),
                           "([^A-Za-z0-9_$.])[0-9]+([.][0-9]+)?", "$1?"), 120) AS waiting_query_redacted,
       LEFT(REGEXP_REPLACE(REGEXP_REPLACE(blocking_query, "'[^']*'", "?"),
                           "([^A-Za-z0-9_$.])[0-9]+([.][0-9]+)?", "$1?"), 120) AS blocking_query_redacted
FROM sys.x$innodb_lock_waits
ORDER BY wait_age_secs DESC
LIMIT 20;

-- Metadata lock waits (a DDL queued behind an open transaction blocks every
-- later query on the table). Needs the wait/lock/metadata instrument, which
-- is on by default in 8.0+.
SELECT object_schema,
       object_name,
       waiting_pid,
       waiting_lock_type,
       waiting_query_secs,
       blocking_pid,
       blocking_lock_type,
       blocking_lock_duration,
       LEFT(REGEXP_REPLACE(REGEXP_REPLACE(waiting_query, "'[^']*'", "?"),
                           "([^A-Za-z0-9_$.])[0-9]+([.][0-9]+)?", "$1?"), 120) AS waiting_query_redacted
FROM sys.x$schema_table_lock_waits
ORDER BY waiting_query_secs DESC
LIMIT 20;
