-- Bad: rank pg_stat_statements by mean time and run EXPLAIN ANALYZE on a
-- write outside a transaction. Both run without error; the assertions
-- show the wrong query picked and the row that was really inserted.

CREATE TABLE obs_orders (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL,
  amount      numeric(10, 2) NOT NULL,
  status      text NOT NULL
);
INSERT INTO obs_orders (customer_id, amount, status)
SELECT g % 5000, (g % 1000) / 10.0, CASE WHEN g % 10 = 0 THEN 'refunded' ELSE 'paid' END
FROM generate_series(1, 200000) AS g;
ANALYZE obs_orders;

SELECT pg_stat_statements_reset(0::oid, oid, 0::bigint) FROM pg_database WHERE datname = current_database();

-- Same workload as the good example: pg_sleep(0.002) stands in for the
-- per-call work of a cheap lookup called 500 times; a report runs 3 times.
SELECT format('SELECT status, pg_sleep(0.002) FROM obs_orders WHERE id = %s', g) FROM generate_series(1, 500) AS g \gexec
SELECT customer_id, sum(amount) FROM obs_orders GROUP BY customer_id ORDER BY 2 DESC LIMIT 10;
SELECT customer_id, sum(amount) FROM obs_orders GROUP BY customer_id ORDER BY 2 DESC LIMIT 10;
SELECT customer_id, sum(amount) FROM obs_orders GROUP BY customer_id ORDER BY 2 DESC LIMIT 10;

-- MISTAKE: ranking by mean_exec_time puts the 3-call report first and
-- hides the lookup that spends more server time in total; you tune the
-- wrong query.
SELECT calls, round(mean_exec_time::numeric, 2) AS mean_ms, left(query, 70) AS query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY mean_exec_time DESC
LIMIT 10;

SELECT assert_true(
  (SELECT query FROM pg_stat_statements
   WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
     AND query LIKE '%FROM obs_orders%'
   ORDER BY mean_exec_time DESC LIMIT 1) LIKE '%GROUP BY customer_id%',
  'ranking by mean picks the 3-call report');
SELECT assert_true(
  (SELECT total_exec_time FROM pg_stat_statements
   WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
     AND query LIKE '%GROUP BY customer_id%')
  <
  (SELECT total_exec_time FROM pg_stat_statements
   WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
     AND query LIKE '%FROM obs_orders WHERE id = %'),
  'yet the lookup it ranked lower costs more in total');

-- MISTAKE: EXPLAIN ANALYZE executes the statement. Without BEGIN/ROLLBACK
-- this "just a plan" check inserts a real row (and fires triggers, takes
-- locks and writes WAL), which on production is a data change.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
INSERT INTO obs_orders (customer_id, amount, status) VALUES (1, 9.99, 'paid');

SELECT assert_true(count(*) = 200001, 'the explained INSERT really inserted a row') FROM obs_orders;
