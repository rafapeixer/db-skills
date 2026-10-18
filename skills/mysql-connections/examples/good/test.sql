-- mysql-connections, good: compute the budget from the server's own
-- settings, size the fleet with the deploy surge, cap each application
-- account with MAX_USER_CONNECTIONS, and check reality in performance_schema.

-- 1. The budget. mysqld permits max_connections + 1 connections; the extra
-- one is only for CONNECTION_ADMIN (or SUPER) accounts, so ordinary
-- accounts share max_connections. Keep a fixed reserve for your own admin
-- session, monitoring and the migration job.
CREATE TEMPORARY TABLE budget AS
SELECT @@GLOBAL.max_connections AS max_connections,
1 AS admin_extra_slot,
10 AS admin_and_monitoring;

CREATE TEMPORARY TABLE app_budget AS
SELECT max_connections - admin_and_monitoring AS app_slots FROM budget;

CALL assert_true((SELECT app_slots FROM app_budget) > 0,
  'the server leaves slots for the application');

-- What the server has seen so far: the high-water mark and failed connects.
CREATE TEMPORARY TABLE seen AS
SELECT
  (SELECT CAST(VARIABLE_VALUE AS UNSIGNED) FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Max_used_connections') AS max_used_connections,
  (SELECT CAST(VARIABLE_VALUE AS UNSIGNED) FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Threads_connected') AS threads_connected,
  (SELECT CAST(VARIABLE_VALUE AS UNSIGNED) FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Aborted_connects') AS aborted_connects,
  (SELECT CAST(VARIABLE_VALUE AS UNSIGNED) FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Connection_errors_max_connections') AS refused_at_max;

CALL assert_true((SELECT max_used_connections >= threads_connected FROM seen),
  'Max_used_connections is the high-water mark of Threads_connected');
CALL assert_true((SELECT refused_at_max FROM seen) = 0,
  'no connection has been refused at max_connections');
SELECT * FROM budget, app_budget, seen;

-- 2. The fleet peak: (replicas + surge) x processes x pool max, per service.
-- Pool lifetime stays below wait_timeout, so the pool retires a connection
-- before the server closes it under the pool.
CREATE TEMPORARY TABLE fleet (
  service        VARCHAR(40) PRIMARY KEY,
  replicas       INT NOT NULL,
  surge          INT NOT NULL,
  processes      INT NOT NULL,
  pool_max       INT NOT NULL,
  max_lifetime_s INT NOT NULL
);
INSERT INTO fleet VALUES
  ('orders-api', 2, 1, 1, 8, 1800),  -- Go: one process, one pool of 8
  ('orders-worker', 1, 1, 1, 4, 1800),
  ('migrations', 1, 0, 1, 1, 1800);

CREATE TEMPORARY TABLE fleet_peak AS
SELECT SUM((replicas + surge) * processes * pool_max) AS peak_connections
FROM fleet;

CALL assert_true((SELECT peak_connections FROM fleet_peak) = 33,
  'peak = (2+1)*1*8 + (1+1)*1*4 + 1*1*1 = 33');
CALL assert_true((SELECT peak_connections FROM fleet_peak)
                 <= (SELECT app_slots FROM app_budget),
  'the fleet fits the budget even mid-deploy');
CALL assert_true(
  (SELECT MAX(max_lifetime_s) FROM fleet) < @@GLOBAL.wait_timeout,
  'every pool retires connections before wait_timeout closes them');

-- 3. Cap each application account at its share of the budget, so a
-- leaking pool fails at its own limit instead of starving everyone else.
DROP USER IF EXISTS 'orders_app'@'%', 'orders_worker'@'%';
CREATE USER 'orders_app'@'%' IDENTIFIED BY 'orders-app-pw'
WITH MAX_USER_CONNECTIONS 24;
CREATE USER 'orders_worker'@'%' IDENTIFIED BY 'orders-worker-pw'
WITH MAX_USER_CONNECTIONS 8;

-- The limit is stored per account (user + host row in mysql.user). 0 would
-- fall back to the global max_user_connections, and 0 there means no limit.
CREATE TEMPORARY TABLE account_limits AS
SELECT user, host, max_user_connections AS account_limit,
COALESCE(NULLIF(max_user_connections, 0),
NULLIF(@@GLOBAL.max_user_connections, 0)) AS effective_limit
FROM mysql.user
WHERE user IN ('orders_app', 'orders_worker');

CALL assert_true(
  (SELECT COUNT(*) FROM account_limits WHERE effective_limit IS NOT NULL) = 2,
  'both application accounts have an effective connection limit');
CALL assert_true(
  (SELECT effective_limit FROM account_limits WHERE user = 'orders_app')
  = (SELECT (replicas + surge) * processes * pool_max FROM fleet
     WHERE service = 'orders-api'),
  'orders_app is capped exactly at its fleet peak, 24');
CALL assert_true(
  (SELECT SUM(effective_limit) FROM account_limits)
  <= (SELECT app_slots FROM app_budget),
  'the account limits add up to no more than the budget');
CALL assert_true(
  (SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES
   WHERE GRANTEE IN ('''orders_app''@''%''', '''orders_worker''@''%''')
   AND PRIVILEGE_TYPE IN ('SUPER', 'CONNECTION_ADMIN')) = 0,
  'no application account can take the admin-only extra slot');
SELECT * FROM account_limits;

-- 4. Count connections per account: this is how you check the formula
-- against reality. This session is one of them.
CALL assert_true(
  (SELECT CURRENT_CONNECTIONS FROM performance_schema.accounts
   WHERE USER = SUBSTRING_INDEX(CURRENT_USER(), '@', 1)
   AND HOST = SUBSTRING_INDEX(CURRENT_USER(), '@', -1)) >= 1
  OR (SELECT COUNT(*) FROM performance_schema.threads
      WHERE PROCESSLIST_USER = SUBSTRING_INDEX(CURRENT_USER(), '@', 1)) >= 1,
  'performance_schema counts this session against its account');

SELECT USER, HOST, CURRENT_CONNECTIONS, TOTAL_CONNECTIONS
FROM performance_schema.accounts
WHERE USER IS NOT NULL
ORDER BY CURRENT_CONNECTIONS DESC;

SELECT PROCESSLIST_USER, PROCESSLIST_COMMAND, COUNT(*) AS connections
FROM performance_schema.threads
WHERE TYPE = 'FOREGROUND' AND PROCESSLIST_USER IS NOT NULL
GROUP BY PROCESSLIST_USER, PROCESSLIST_COMMAND
ORDER BY connections DESC;

DROP USER 'orders_app'@'%', 'orders_worker'@'%';
