-- Good: short transactions, a SKIP LOCKED work queue, bounded lock waits,
-- retry of the whole transaction on 40001, transaction-scoped advisory
-- locks, and timeouts set on the role. A second session comes from dblink.
CREATE EXTENSION dblink;

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

-- 1. Work queue. Worker 1 claims a batch and its transaction is still open.
SELECT dblink_exec('worker1', 'BEGIN');
CREATE TEMP TABLE claimed_by_worker1 AS
SELECT id FROM dblink('worker1', $$
  WITH next AS (
    SELECT id FROM jobs
    WHERE status = 'queued'
    ORDER BY id
    LIMIT 10
    FOR UPDATE SKIP LOCKED
  )
  UPDATE jobs SET status = 'running'
  FROM next WHERE jobs.id = next.id
  RETURNING jobs.id
$$) AS t(id bigint);

-- Worker 2 (this session) claims the next batch without waiting for worker 1.
CREATE TEMP TABLE claimed_by_worker2 (id bigint);
BEGIN;
-- Short here so the example runs fast; production values are on the role (below).
SET LOCAL lock_timeout = '200ms';
WITH next AS (
  SELECT id FROM jobs
  WHERE status = 'queued'
  ORDER BY id
  LIMIT 10
  FOR UPDATE SKIP LOCKED
), claimed AS (
  UPDATE jobs SET status = 'running'
  FROM next WHERE jobs.id = next.id
  RETURNING jobs.id
)
INSERT INTO claimed_by_worker2 SELECT id FROM claimed;

-- A row someone else holds: fail fast instead of queueing behind them.
SELECT assert_error('SELECT id FROM jobs WHERE id = 1 FOR UPDATE NOWAIT', '55P03', 'NOWAIT raises lock_not_available on a held row');
SELECT assert_error($$UPDATE jobs SET status = 'cancelled' WHERE id = 1$$, '55P03', 'lock_timeout bounds an implicit row lock wait');
COMMIT;

SELECT assert_true((SELECT count(*) FROM claimed_by_worker1) = 10, 'worker 1 claimed 10 jobs');
SELECT assert_true((SELECT count(*) FROM claimed_by_worker2) = 10, 'worker 2 claimed 10 jobs while worker 1 held its batch');
SELECT assert_true(NOT EXISTS (SELECT 1 FROM claimed_by_worker1 JOIN claimed_by_worker2 USING (id)), 'no job claimed twice');
SELECT assert_true(current_setting('lock_timeout') = '0', 'SET LOCAL ended with the transaction');
SELECT dblink_exec('worker1', 'COMMIT');
SELECT assert_true((SELECT count(*) FROM jobs WHERE status = 'running') = 20, 'both batches committed');

-- 2. REPEATABLE READ: a concurrent write raises 40001; retry the WHOLE transaction.
-- Attempt 1 reads the balance, then another session deposits 50 and commits.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance AS seen FROM accounts WHERE id = 1 \gset
SELECT dblink_exec('worker1', 'UPDATE accounts SET balance = balance + 50 WHERE id = 1');
SELECT assert_error(format('UPDATE accounts SET balance = %s + 10 WHERE id = 1', :'seen'), '40001', 'repeatable read refuses to overwrite a concurrent update');
ROLLBACK;

-- Attempt 2 starts over: new snapshot, re-read, recompute, write.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance AS seen FROM accounts WHERE id = 1 \gset
UPDATE accounts SET balance = :seen + 10 WHERE id = 1;
COMMIT;
SELECT assert_true((SELECT balance FROM accounts WHERE id = 1) = 160, 'both the deposit and the retried update are kept');

-- 3. Advisory lock scoped to the transaction: COMMIT releases it.
BEGIN;
SELECT pg_advisory_xact_lock(42);
UPDATE jobs SET status = 'done' WHERE status = 'running';
COMMIT;
SELECT assert_true(NOT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND objid = 42), 'no advisory lock left after COMMIT');
SELECT assert_true((SELECT ok FROM dblink('worker1', 'SELECT pg_try_advisory_xact_lock(42)') AS r(ok boolean)), 'another session can take the lock');

-- 4. statement_timeout cancels a runaway statement (57014, checked on the
-- remote session because PL/pgSQL cannot catch query_canceled).
SELECT dblink_exec('worker1', $$SET statement_timeout = '100ms'$$);
SELECT * FROM dblink('worker1', 'SELECT pg_sleep(2)', false) AS r(v text);
SELECT assert_true(dblink_error_message('worker1') LIKE '%statement timeout%', 'statement_timeout canceled the 2 s statement');
SELECT dblink_exec('worker1', 'RESET statement_timeout');

-- 5. Timeouts on the role, so every connection gets them, pooled or not.
DROP ROLE IF EXISTS txlock_app;
CREATE ROLE txlock_app LOGIN;
ALTER ROLE txlock_app SET statement_timeout = '30s';
ALTER ROLE txlock_app SET lock_timeout = '5s';
ALTER ROLE txlock_app SET idle_in_transaction_session_timeout = '60s';
DO $$
BEGIN
  IF current_setting('server_version_num')::int >= 170000 THEN
    EXECUTE $q$ALTER ROLE txlock_app SET transaction_timeout = '2min'$q$;
  END IF;
END
$$;

SELECT dblink_connect('app', 'dbname=' || current_database() || ' user=txlock_app');
SELECT assert_true((SELECT s FROM dblink('app', $$SELECT current_setting('statement_timeout')$$) AS r(s text)) = '30s', 'role statement_timeout applies on connect');
SELECT assert_true((SELECT s FROM dblink('app', $$SELECT current_setting('lock_timeout')$$) AS r(s text)) = '5s', 'role lock_timeout applies on connect');
SELECT assert_true((SELECT s FROM dblink('app', $$SELECT current_setting('idle_in_transaction_session_timeout')$$) AS r(s text)) = '1min', 'role idle_in_transaction_session_timeout applies on connect');
DO $$
BEGIN
  IF current_setting('server_version_num')::int >= 170000 THEN
    PERFORM assert_true((SELECT s FROM dblink('app', $q$SELECT current_setting('transaction_timeout')$q$) AS r(s text)) = '2min', 'role transaction_timeout applies on connect (PG 17+)');
  END IF;
END
$$;
SELECT dblink_disconnect('app');
DROP ROLE txlock_app;

-- 6. idle_in_transaction_session_timeout terminates a session that opened a
-- transaction and went quiet, which releases its locks and its snapshot.
SELECT dblink_connect('idle', 'dbname=' || current_database() || ' user=postgres');
SELECT pid AS idle_pid FROM dblink('idle', 'SELECT pg_backend_pid()') AS r(pid int) \gset
SELECT dblink_exec('idle', $$SET idle_in_transaction_session_timeout = '200ms'$$);
SELECT dblink_exec('idle', 'BEGIN');
SELECT dblink_exec('idle', $$UPDATE jobs SET status = 'queued' WHERE id = 1$$);
SELECT pg_sleep(1);
SELECT assert_true(NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = :idle_pid), 'idle-in-transaction session was terminated');
SELECT assert_true((SELECT status FROM jobs WHERE id = 1) = 'done', 'its uncommitted update was rolled back');
SELECT dblink_disconnect('idle');

-- transaction_timeout (PG 17+) caps the whole transaction, idle or busy.
DO $$
DECLARE
  tx_pid int;
BEGIN
  IF current_setting('server_version_num')::int < 170000 THEN
    RETURN;
  END IF;
  PERFORM dblink_connect('longtx', 'dbname=' || current_database() || ' user=postgres');
  SELECT pid INTO tx_pid FROM dblink('longtx', 'SELECT pg_backend_pid()') AS r(pid int);
  PERFORM dblink_exec('longtx', $q$SET transaction_timeout = '200ms'$q$);
  PERFORM dblink_exec('longtx', 'BEGIN');
  PERFORM pg_sleep(1);
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = tx_pid), 'transaction_timeout terminated the session (PG 17+)');
  PERFORM dblink_disconnect('longtx');
END
$$;

SELECT dblink_disconnect('worker1');
