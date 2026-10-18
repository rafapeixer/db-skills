-- Bad: a transaction left open across a network call, a queue claimed with
-- plain FOR UPDATE, a retry of one statement instead of the transaction,
-- and a session advisory lock taken inside a transaction.
CREATE EXTENSION dblink;
CREATE EXTENSION pgstattuple;

CREATE TABLE jobs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  status text NOT NULL DEFAULT 'queued',
  payload text NOT NULL
);
INSERT INTO jobs (payload) SELECT 'job ' || g FROM generate_series(1, 1000) AS g;

CREATE TABLE accounts (id int PRIMARY KEY, balance numeric NOT NULL);
INSERT INTO accounts VALUES (1, 100);
ANALYZE jobs;
ANALYZE accounts;

SELECT dblink_connect('worker1', 'dbname=' || current_database() || ' user=postgres');
SELECT pid AS worker1_pid FROM dblink('worker1', 'SELECT pg_backend_pid()') AS r(pid int) \gset

-- 1. Worker 1 claims a job, then calls an external API before COMMIT.
SELECT dblink_exec('worker1', 'BEGIN');
SELECT dblink_exec('worker1', $$UPDATE jobs SET status = 'running' WHERE id = 1$$);
-- MISTAKE: the transaction stays open while the application waits on the
-- network. The row lock and the transaction ID are held for as long as the
-- API takes, and no timeout on the role ends it.
SELECT assert_true((SELECT state FROM pg_stat_activity WHERE pid = :worker1_pid) = 'idle in transaction', 'worker 1 sits idle in transaction');

-- 2. Worker 2 claims the queue with plain FOR UPDATE.
BEGIN;
-- lock_timeout is set only so the example can assert the wait; without it
-- this statement waits until worker 1's API call returns.
SET LOCAL lock_timeout = '200ms';
-- MISTAKE: no SKIP LOCKED, so every worker queues behind the oldest claimed row.
SELECT assert_error($$SELECT id FROM jobs WHERE status = 'queued' ORDER BY id LIMIT 10 FOR UPDATE$$, '55P03', 'second worker blocks on the first worker''s row');
COMMIT;

-- 3. The open transaction holds back vacuum for the whole database.
DELETE FROM jobs WHERE id > 500;
VACUUM jobs;
-- MISTAKE: 500 dead rows survive VACUUM because worker 1's transaction began first.
SELECT assert_true((SELECT dead_tuple_count FROM pgstattuple('jobs')) >= 500, 'dead rows not removable while worker 1 is open');
SELECT dblink_exec('worker1', 'COMMIT');
VACUUM jobs;
SELECT assert_true((SELECT dead_tuple_count FROM pgstattuple('jobs')) = 0, 'same VACUUM removes them once the transaction ends');

-- 4. REPEATABLE READ with a retry of the failed statement only.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance AS seen FROM accounts WHERE id = 1 \gset
SELECT dblink_exec('worker1', 'UPDATE accounts SET balance = balance + 50 WHERE id = 1');
SELECT assert_error(format('UPDATE accounts SET balance = %s + 10 WHERE id = 1', :'seen'), '40001', 'concurrent update detected');
ROLLBACK;
-- MISTAKE: the "retry" re-sends the same UPDATE with the value read in the
-- failed attempt instead of re-running the whole transaction. The 50 deposit is lost.
UPDATE accounts SET balance = :seen + 10 WHERE id = 1;
SELECT assert_true((SELECT balance FROM accounts WHERE id = 1) = 110, 'lost update: balance should be 160');

-- 5. Session advisory lock taken inside a transaction.
BEGIN;
-- MISTAKE: pg_advisory_lock is session-scoped; COMMIT does not release it.
-- Behind a transaction pooler the server connection goes back to the pool
-- still holding the lock, and the next client that gets it inherits it.
SELECT pg_advisory_lock(42);
COMMIT;
SELECT assert_true(EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND objid = 42 AND pid = pg_backend_pid()), 'lock survives COMMIT');
SELECT assert_true(NOT (SELECT ok FROM dblink('worker1', 'SELECT pg_try_advisory_lock(42)') AS r(ok boolean)), 'every other session is locked out');
SELECT pg_advisory_unlock(42);

SELECT dblink_disconnect('worker1');
