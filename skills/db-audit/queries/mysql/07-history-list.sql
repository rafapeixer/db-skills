-- InnoDB history list length: undo records not yet purged. It grows while
-- old read views stay open (long or idle transactions) and slows reads that
-- must walk old row versions.
SELECT NAME, COUNT AS history_list_length, STATUS
FROM information_schema.INNODB_METRICS
WHERE NAME = 'trx_rseg_history_len';

SELECT @@innodb_purge_threads AS purge_threads,
       @@innodb_max_purge_lag AS max_purge_lag;

-- Oldest open transactions: the usual reason the list does not shrink.
SELECT trx_id,
       trx_state,
       trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s,
       trx_mysql_thread_id,
       trx_isolation_level,
       trx_rows_locked,
       trx_rows_modified
FROM information_schema.INNODB_TRX
ORDER BY trx_started
LIMIT 10;
