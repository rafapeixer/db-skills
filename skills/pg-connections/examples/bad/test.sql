-- pg-connections, bad: a fleet sized by "replicas x pool" without the
-- process count or the deploy surge, against a small instance, and an
-- application role with no connection limit.

CREATE EXTENSION dblink;

-- A db.t4g.micro-sized server, as in the go-skills benchmark: max_connections 80.
CREATE TEMP TABLE budget AS
SELECT 80 AS max_connections, 3 AS superuser_reserved, 0 AS reserved;

-- Python: 12 replicas, 2 worker processes each, a pool of 4 per worker.
CREATE TEMP TABLE fleet (
  service      text PRIMARY KEY,
  replicas     int NOT NULL,
  surge        int NOT NULL,
  processes    int NOT NULL,
  pool_max     int NOT NULL
);
INSERT INTO fleet VALUES ('orders-api', 12, 3, 2, 4);

-- MISTAKE: the estimate multiplies replicas by pool and forgets the worker
-- processes: 12 * 4 = 48 looks comfortable on an 80-connection server.
SELECT assert_true((SELECT replicas * pool_max FROM fleet) = 48,
  'the naive estimate says 48');

-- What the fleet really opens: 12 * 2 * 4 = 96, above the 77 slots
-- ordinary roles can use (80 - 3 superuser_reserved_connections).
SELECT assert_true(
  (SELECT replicas * processes * pool_max FROM fleet)
  > (SELECT max_connections - superuser_reserved - reserved FROM budget),
  '96 steady-state connections do not fit 77 usable slots');

-- MISTAKE: the deploy surge (3 extra replicas, 25%) is not counted either:
-- mid-deploy the fleet asks for 120, and new pods fail with
-- "sorry, too many clients already" (SQLSTATE 53300).
SELECT assert_true(
  (SELECT (replicas + surge) * processes * pool_max FROM fleet) = 120,
  'mid-deploy the fleet wants 120 connections');

-- MISTAKE: the application role has no CONNECTION LIMIT (-1, the default),
-- so one leaking pool can take every non-reserved slot on the server,
-- starving every other service and the migrations job.
DROP ROLE IF EXISTS reports_app;
CREATE ROLE reports_app LOGIN;
SELECT assert_true(
  (SELECT rolconnlimit FROM pg_roles WHERE rolname = 'reports_app') = -1,
  'reports_app is unlimited');

SELECT dblink_connect('r' || i,
  'dbname=' || current_database() || ' user=reports_app application_name=reports')
FROM generate_series(1, 6) AS i;

SELECT assert_true(
  (SELECT count(*) FROM pg_stat_activity WHERE usename = 'reports_app') = 6,
  'nothing stopped reports_app from opening 6 idle connections');

SELECT dblink_disconnect('r' || i) FROM generate_series(1, 6) AS i;
DROP ROLE reports_app;
