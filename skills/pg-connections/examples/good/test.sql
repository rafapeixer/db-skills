-- pg-connections, good: compute the connection budget from the server's
-- own settings, size the fleet against it (deploy surge included), cap each
-- application role with CONNECTION LIMIT, and count connections per
-- application_name.

CREATE EXTENSION dblink;

-- 1. The budget: what ordinary roles can actually open.
-- reserved_connections exists only on PG 16+; on older majors it counts as 0.
CREATE TEMP TABLE budget AS
SELECT current_setting('max_connections')::int AS max_connections,
       current_setting('superuser_reserved_connections')::int AS superuser_reserved,
       CASE WHEN current_setting('server_version_num')::int >= 160000
            THEN current_setting('reserved_connections', true)::int
            ELSE 0 END AS reserved,
       5 AS admin_and_monitoring;

CREATE TEMP VIEW app_budget AS
SELECT max_connections - superuser_reserved - reserved - admin_and_monitoring AS app_slots
FROM budget;

SELECT assert_true((SELECT reserved FROM budget) IS NOT NULL,
  'reserved_connections is gated by version, never NULL');
SELECT assert_true((SELECT app_slots FROM app_budget) < (SELECT max_connections FROM budget),
  'the application budget is smaller than max_connections');

-- 2. The fleet, at its peak: replicas during a rolling deploy (surge),
-- processes per replica, pool size per process.
CREATE TEMP TABLE fleet (
  service      text PRIMARY KEY,
  replicas     int NOT NULL,
  surge        int NOT NULL,
  processes    int NOT NULL,
  pool_max     int NOT NULL
);
INSERT INTO fleet VALUES
  ('orders-api', 2, 1, 1, 8),  -- Go: one process, one pool of 8
  ('orders-worker', 1, 1, 1, 4),
  ('migrations', 1, 0, 1, 1);

CREATE TEMP VIEW fleet_peak AS
SELECT sum((replicas + surge) * processes * pool_max)::int AS peak_connections
FROM fleet;

SELECT assert_true((SELECT peak_connections FROM fleet_peak) = 33,
  'peak = (2+1)*1*8 + (1+1)*1*4 + 1*1*1 = 33');
SELECT assert_true((SELECT peak_connections FROM fleet_peak)
                   <= (SELECT app_slots FROM app_budget),
  'the fleet fits the budget even mid-deploy');

-- 3. Cap the application role, so a runaway pool fails at its own limit
-- instead of taking every slot on the server.
DROP ROLE IF EXISTS orders_app;
CREATE ROLE orders_app LOGIN;
ALTER ROLE orders_app CONNECTION LIMIT 3;

-- dblink reports any failed connection as 08001; this unwraps the server's
-- "too many connections for role" (SQLSTATE 53300) so the test can assert it.
CREATE FUNCTION connect_as_orders_app(conn_name text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  detail text;
BEGIN
  PERFORM dblink_connect(conn_name,
    'dbname=' || current_database() || ' user=orders_app application_name=orders-api');
EXCEPTION WHEN sqlclient_unable_to_establish_sqlconnection THEN
  GET STACKED DIAGNOSTICS detail = PG_EXCEPTION_DETAIL;
  IF detail LIKE '%too many connections for role%' THEN
    RAISE EXCEPTION '%', detail USING ERRCODE = '53300';
  END IF;
  RAISE;
END
$$;

SELECT connect_as_orders_app('c1');
SELECT connect_as_orders_app('c2');
SELECT connect_as_orders_app('c3');
SELECT assert_error($$SELECT connect_as_orders_app('c4')$$, '53300',
  'the fourth connection hits the role limit');

-- 4. Count connections per application_name: this is how you check the
-- formula against reality. Idle connections still hold a slot each.
SELECT assert_true(
  (SELECT count(*) FROM pg_stat_activity
   WHERE application_name = 'orders-api' AND usename = 'orders_app') = 3,
  'pg_stat_activity shows the 3 orders-api connections');
SELECT assert_true(
  (SELECT bool_and(state = 'idle') FROM pg_stat_activity
   WHERE application_name = 'orders-api'),
  'all of them are idle, and each still counts against max_connections');

SELECT application_name, usename, state, count(*) AS connections
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY application_name, usename, state
ORDER BY connections DESC;

SELECT dblink_disconnect('c1');
SELECT dblink_disconnect('c2');
SELECT dblink_disconnect('c3');
DROP ROLE orders_app;
