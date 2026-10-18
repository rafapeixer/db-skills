-- Session guard. Run first, in the same session as every other file.
-- The role setup in skills/db-audit/setup/pg-audit-role.sql already sets these on the role;
-- setting them again here covers a role the user configured differently.
SET statement_timeout = '5s';
SET lock_timeout = '1s';
SET idle_in_transaction_session_timeout = '30s';
SET default_transaction_read_only = on;

-- Who am I, and is the session really read-only with timeouts?
-- Stop the audit if rolsuper is true or transaction_read_only is off.
SELECT current_user AS connected_as,
       r.rolsuper,
       r.rolcreaterole,
       r.rolcreatedb,
       r.rolreplication,
       r.rolbypassrls,
       current_setting('transaction_read_only') AS transaction_read_only,
       current_setting('statement_timeout') AS statement_timeout,
       current_setting('lock_timeout') AS lock_timeout,
       pg_is_in_recovery() AS on_replica
FROM pg_roles r
WHERE r.rolname = current_user;

-- Predefined roles an audit role must not have. Any row here: stop and ask
-- the user to connect with the role from skills/db-audit/setup/pg-audit-role.sql.
-- Filtering pg_roles first keeps this valid on versions without some roles.
SELECT r.rolname AS risky_role_membership
FROM pg_roles r
WHERE r.rolname IN ('pg_write_all_data', 'pg_maintain', 'pg_signal_backend',
                    'pg_read_server_files', 'pg_write_server_files',
                    'pg_execute_server_program', 'pg_checkpoint',
                    'pg_create_subscription', 'rds_superuser')
  AND pg_has_role(current_user, r.oid, 'MEMBER');

-- Write privileges this role holds. Expected: 0 everywhere.
SELECT (SELECT count(*)
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('r', 'p')
           AND n.nspname NOT IN ('pg_catalog', 'information_schema')
           AND n.nspname NOT LIKE 'pg_toast%'
           AND has_table_privilege(c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')) AS writable_tables,
       (SELECT count(*)
          FROM pg_namespace n
         WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
           AND n.nspname NOT LIKE 'pg_toast%'
           AND has_schema_privilege(n.oid, 'CREATE')) AS schemas_with_create,
       has_database_privilege(current_database(), 'CREATE') AS database_create;
