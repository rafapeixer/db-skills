-- mysql-connections, bad: a fleet sized by "replicas x pool" without the
-- process count or the deploy surge, against a small RDS instance, an
-- application account with no connection limit, and pools that outlive
-- wait_timeout.

-- A db.t3.micro-sized RDS for MySQL instance: AWS documents a default
-- max_connections of about 60 there, below the naive 1 GiB / 12582880 = 85,
-- because DBInstanceClassMemory excludes memory reserved for the OS and RDS.
CREATE TEMPORARY TABLE budget AS
SELECT 60 AS max_connections, 10 AS admin_and_monitoring;

CALL assert_true(FLOOR(1073741824 / 12582880) = 85,
  'the formula on nominal 1 GiB says 85, the real instance gives about 60');

-- Python: 12 replicas, 2 worker processes each, a pool of 4 per worker.
CREATE TEMPORARY TABLE fleet (
  service        VARCHAR(40) PRIMARY KEY,
  replicas       INT NOT NULL,
  surge          INT NOT NULL,
  processes      INT NOT NULL,
  pool_max       INT NOT NULL,
  max_lifetime_s INT NOT NULL
);
INSERT INTO fleet VALUES ('orders-api', 12, 3, 2, 4, 0);

-- MISTAKE: the estimate multiplies replicas by pool and forgets the worker
-- processes: 12 * 4 = 48 looks like it fits a 60-connection server.
CALL assert_true((SELECT replicas * pool_max FROM fleet) = 48,
  'the naive estimate says 48');

-- What the fleet really opens: 12 * 2 * 4 = 96, above the 50 slots left
-- after the admin and monitoring reserve, and above max_connections itself.
CALL assert_true(
  (SELECT replicas * processes * pool_max FROM fleet)
  > (SELECT max_connections FROM budget),
  '96 steady-state connections do not fit 60');

-- MISTAKE: the deploy surge (3 extra replicas, 25%) is not counted either:
-- mid-deploy the fleet asks for 120, and new pods get "Too many connections"
-- (Connection_errors_max_connections goes up).
CALL assert_true(
  (SELECT (replicas + surge) * processes * pool_max FROM fleet) = 120,
  'mid-deploy the fleet wants 120 connections, double the server limit');

-- MISTAKE: max lifetime 0 (never retire) with the default wait_timeout of
-- 28800 s: the server closes idle sockets after 8 hours and the pool hands
-- a dead connection to the next request, which fails with a lost connection.
CALL assert_true(
  (SELECT max_lifetime_s = 0 OR max_lifetime_s >= @@GLOBAL.wait_timeout
   FROM fleet),
  'the pool keeps connections longer than the server does');

-- MISTAKE: the application account has no MAX_USER_CONNECTIONS (0, the
-- default) and the global max_user_connections is 0 too, so the account is
-- unlimited: one leaking pool can take every slot and starve the others.
DROP USER IF EXISTS 'reports_app'@'%';
CREATE USER 'reports_app'@'%' IDENTIFIED BY 'reports-app-pw';
CALL assert_true(
  (SELECT max_user_connections FROM mysql.user
   WHERE user = 'reports_app' AND host = '%') = 0
  AND @@GLOBAL.max_user_connections = 0,
  'reports_app has no connection limit at all');

-- MISTAKE: granting CONNECTION_ADMIN to the application account lets it
-- take the one extra slot mysqld keeps for administrators, so when the
-- fleet saturates the server nobody can get in to fix it.
GRANT CONNECTION_ADMIN ON *.* TO 'reports_app'@'%';
CALL assert_true(
  (SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES
   WHERE GRANTEE = '''reports_app''@''%'''
   AND PRIVILEGE_TYPE = 'CONNECTION_ADMIN') = 1,
  'reports_app can use the admin-only slot');

DROP USER 'reports_app'@'%';
