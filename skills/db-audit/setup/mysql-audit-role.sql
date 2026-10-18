-- Read-only audit account for the db-skills workflows (db-audit, db-explain,
-- db-connection-budget) on MySQL 8.4+.
--
-- YOU run this file, as an administrator (on RDS or Aurora: the master user).
-- The agent never runs it: it creates an account and grants privileges.
-- Read-only is enforced here, by the server, not by the agent or by any MCP
-- server's "read-only mode".
--
-- Before running: replace the password and the host pattern ('%' allows any
-- host; narrow it to where the agent connects from), and app_db below.
-- Prefer pointing the workflows at a read replica.

CREATE USER 'db_audit'@'%' IDENTIFIED BY 'change-me'
  WITH MAX_USER_CONNECTIONS 3;

-- See every thread, InnoDB transactions and lock data.
GRANT PROCESS ON *.* TO 'db_audit'@'%';
-- The sys views read performance_schema and run sys functions/procedures.
GRANT SELECT ON performance_schema.* TO 'db_audit'@'%';
GRANT SELECT, EXECUTE ON sys.* TO 'db_audit'@'%';

-- OPTIONAL, only if you agree to give the account read access to table data.
-- information_schema (and the sys index views built on it) shows only tables
-- the account has some privilege on, and EXPLAIN needs the same privileges as
-- the statement it explains. Without this, index findings and db-explain
-- cannot see app_db.
-- GRANT SELECT, SHOW VIEW ON app_db.* TO 'db_audit'@'%';

-- MySQL has no per-account default for read-only or timeouts. The workflows
-- set these at the start of every session (queries/mysql/00-session.sql):
--   SET SESSION transaction_read_only = ON;
--   SET SESSION max_execution_time = 5000;   -- ms, read-only SELECTs
--   SET SESSION lock_wait_timeout = 5;       -- s, metadata locks
-- The real boundary is the absence of write privileges above.

-- NEVER grant to this account: FILE (reads and writes server files; the
-- read-only bypass in an MySQL MCP server only mattered with FILE), SUPER,
-- SYSTEM_VARIABLES_ADMIN, CONNECTION_ADMIN, BINLOG_ADMIN, RELOAD, SHUTDOWN,
-- CREATE USER, GRANT OPTION, or INSERT/UPDATE/DELETE/CREATE/DROP/ALTER/INDEX
-- on any schema. No privileges on the mysql schema are needed.

-- To remove the account later:
--   DROP USER 'db_audit'@'%';
