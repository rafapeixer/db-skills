-- Long-running statements and idle-in-transaction sessions (a Sleep thread
-- that still has an InnoDB transaction open). Processlist INFO is raw text
-- with literals, so quoted strings and numbers are redacted.
SELECT p.ID AS thread,
       p.USER AS user,
       p.DB AS db,
       p.COMMAND AS command,
       p.TIME AS seconds_in_state,
       p.STATE AS state,
       t.trx_state,
       TIMESTAMPDIFF(SECOND, t.trx_started, NOW()) AS trx_age_s,
       t.trx_rows_locked,
       t.trx_rows_modified,
       (p.COMMAND = 'Sleep' AND t.trx_id IS NOT NULL) AS idle_in_transaction,
       LEFT(REGEXP_REPLACE(REGEXP_REPLACE(p.INFO, "'[^']*'", "?"),
                           "([^A-Za-z0-9_$.])[0-9]+([.][0-9]+)?", "$1?"), 200) AS query_redacted
FROM performance_schema.processlist p
LEFT JOIN information_schema.INNODB_TRX t ON t.trx_mysql_thread_id = p.ID
WHERE p.ID <> CONNECTION_ID()
  AND p.COMMAND NOT IN ('Daemon', 'Binlog Dump', 'Binlog Dump GTID')
  AND (t.trx_id IS NOT NULL OR (p.COMMAND <> 'Sleep' AND p.TIME >= 60))
ORDER BY t.trx_started IS NULL, t.trx_started, p.TIME DESC
LIMIT 50;
