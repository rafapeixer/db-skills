-- Session guard. Run first, in the same session as every other file.
-- MySQL has no per-account defaults for these, so they are set per session.
-- transaction_read_only makes the server reject writes in this session;
-- max_execution_time (ms) applies to read-only SELECT statements;
-- lock_wait_timeout (s) bounds metadata lock waits.
SET SESSION transaction_read_only = ON;
SET SESSION max_execution_time = 5000;
SET SESSION lock_wait_timeout = 5;
SET SESSION innodb_lock_wait_timeout = 5;

-- Who am I, is the session read-only, and is this a replica?
SELECT CURRENT_USER() AS connected_as,
       @@session.transaction_read_only AS transaction_read_only,
       @@session.max_execution_time AS max_execution_time_ms,
       @@session.lock_wait_timeout AS lock_wait_timeout_s,
       @@global.read_only AS server_read_only,
       @@global.super_read_only AS server_super_read_only;

-- Privileges an audit account must not have. Any row here: stop and ask the
-- user to connect with the account from skills/db-audit/setup/mysql-audit-role.sql.
SELECT 'global' AS scope, PRIVILEGE_TYPE AS risky_privilege, NULL AS on_schema
FROM information_schema.USER_PRIVILEGES
WHERE GRANTEE = CONCAT("'", SUBSTRING_INDEX(CURRENT_USER(), '@', 1), "'@'",
                       SUBSTRING_INDEX(CURRENT_USER(), '@', -1), "'")
  AND PRIVILEGE_TYPE IN ('SUPER', 'FILE', 'INSERT', 'UPDATE', 'DELETE', 'CREATE', 'DROP', 'ALTER',
                         'INDEX', 'CREATE USER', 'SHUTDOWN', 'RELOAD', 'GRANT OPTION',
                         'SYSTEM_VARIABLES_ADMIN', 'CONNECTION_ADMIN', 'BINLOG_ADMIN')
UNION ALL
SELECT 'schema', PRIVILEGE_TYPE, TABLE_SCHEMA
FROM information_schema.SCHEMA_PRIVILEGES
WHERE GRANTEE = CONCAT("'", SUBSTRING_INDEX(CURRENT_USER(), '@', 1), "'@'",
                       SUBSTRING_INDEX(CURRENT_USER(), '@', -1), "'")
  AND PRIVILEGE_TYPE IN ('INSERT', 'UPDATE', 'DELETE', 'CREATE', 'DROP', 'ALTER', 'INDEX');
