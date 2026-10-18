-- Read-only audit role for the db-skills workflows (db-audit, db-explain,
-- db-connection-budget) on PostgreSQL.
--
-- YOU run this file, as an administrator (on RDS or Aurora: the master user).
-- The agent never runs it: it creates a role and grants privileges.
-- Read-only is enforced here, by the database, not by the agent or by any
-- MCP server's "read-only mode".
--
-- Before running: replace the password (or use your usual secret store) and
-- the database name app_db. Prefer creating it on a read replica's primary
-- and connecting the workflows to the replica.

CREATE ROLE db_audit LOGIN PASSWORD 'change-me'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 3;

-- Statistics and settings, no table data: pg_monitor includes
-- pg_read_all_settings, pg_read_all_stats and pg_stat_scan_tables.
-- pg_read_all_stats is what lets the role see other users' query texts in
-- pg_stat_statements and pg_stat_activity.
GRANT pg_monitor TO db_audit;

-- Only needed if CONNECT was revoked from PUBLIC on your database.
GRANT CONNECT ON DATABASE app_db TO db_audit;

-- Guards set on the role, so they apply to every session even if a client
-- forgets them. default_transaction_read_only is a guard against accidents:
-- a session can turn it off, which is why the role must also hold no write
-- privilege (it holds none above).
ALTER ROLE db_audit SET default_transaction_read_only = on;
ALTER ROLE db_audit SET statement_timeout = '5s';
ALTER ROLE db_audit SET lock_timeout = '1s';
ALTER ROLE db_audit SET idle_in_transaction_session_timeout = '30s';
-- PostgreSQL 17+ only:
-- ALTER ROLE db_audit SET transaction_timeout = '60s';

-- PostgreSQL 16+ only, optional: lets the audit connect when ordinary slots
-- are exhausted. Needs reserved_connections > 0 in the server settings.
-- GRANT pg_use_reserved_connections TO db_audit;

-- OPTIONAL, only if you agree to give the role read access to table data.
-- db-explain needs SELECT on the tables of the query it explains (EXPLAIN
-- checks the same privileges as the query). It does not bypass row-level
-- security. Prefer the narrow form when you only explain a few tables.
-- GRANT pg_read_all_data TO db_audit;
-- GRANT USAGE ON SCHEMA app TO db_audit;
-- GRANT SELECT ON app.orders, app.customers TO db_audit;

-- NEVER grant to this role: SUPERUSER, rds_superuser, the master user's
-- roles, pg_write_all_data, pg_maintain, pg_signal_backend, pg_checkpoint,
-- pg_create_subscription, pg_read_server_files, pg_write_server_files,
-- pg_execute_server_program, or any INSERT/UPDATE/DELETE/TRUNCATE/CREATE
-- privilege. The server-file and program roles can reach superuser-level
-- access; COPY ... TO PROGRAM is how a read-only MCP mode was bypassed.

-- pg_stat_statements (top statements) is an administrator change, not part
-- of this role: add it to shared_preload_libraries (restart; on RDS a custom
-- parameter group and reboot), then in the database:
--   CREATE EXTENSION pg_stat_statements;

-- To remove the role later:
--   DROP ROLE db_audit;
