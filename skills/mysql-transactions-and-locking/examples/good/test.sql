-- Good: explicit short transactions, a SKIP LOCKED work queue, NOWAIT and
-- short per-session lock timeouts, a full ROLLBACK after a lock wait timeout,
-- READ COMMITTED for a range lock that must not block inserts, and rows
-- locked in a consistent order. The second session is an event: the event
-- scheduler runs its body in its own connection while this session goes on.
SET GLOBAL event_scheduler = ON;

CREATE TABLE jobs (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  status VARCHAR(16) NOT NULL DEFAULT 'queued',
  worker INT NULL,
  payload VARCHAR(100) NOT NULL,
  KEY idx_jobs_status (status, id)
);
INSERT INTO jobs (payload)
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000)
SELECT CONCAT('job ', n) FROM seq;

-- Orders for even account ids only (2, 4, ..., 2000), so the index has gaps.
CREATE TABLE orders (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  account_id INT NOT NULL,
  amount INT NOT NULL,
  KEY idx_orders_account (account_id)
);
INSERT INTO orders (account_id, amount)
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000)
SELECT n * 2, 100 FROM seq;

CREATE TABLE accounts (id INT PRIMARY KEY, balance INT NOT NULL);
INSERT INTO accounts VALUES (1, 100), (2, 100);

CREATE TABLE audit_log (id BIGINT AUTO_INCREMENT PRIMARY KEY, msg VARCHAR(100) NOT NULL);
ANALYZE TABLE jobs, orders, accounts;

DELIMITER $$

-- assert_errno is assert_error keyed on the MySQL error number, because
-- NOWAIT (3572) and lock wait timeout (1205) share SQLSTATE HY000.
CREATE PROCEDURE assert_errno(IN stmt TEXT, IN expected INT, IN msg VARCHAR(255))
BEGIN
  DECLARE got INT DEFAULT NULL;
  DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    GET DIAGNOSTICS CONDITION 1 got = MYSQL_ERRNO;
  SET @assert_stmt = stmt;
  PREPARE s FROM @assert_stmt;
  IF got IS NULL THEN
    EXECUTE s;
    DEALLOCATE PREPARE s;
  END IF;
  IF got IS NULL THEN
    SET @assert_msg = LEFT(CONCAT('assertion failed: ', msg, ': statement succeeded'), 128);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = @assert_msg;
  ELSEIF got <> expected THEN
    SET @assert_msg = LEFT(CONCAT('assertion failed: ', msg, ': expected ', expected, ', got ', got), 128);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = @assert_msg;
  END IF;
END$$

-- Waits until another session holds a row lock on the table.
CREATE PROCEDURE wait_for_lock(IN tbl VARCHAR(64))
BEGIN
  DECLARE tries INT DEFAULT 0;
  WHILE (SELECT COUNT(*) FROM performance_schema.data_locks
         WHERE object_schema = DATABASE() AND object_name = tbl
           AND lock_type = 'RECORD' AND thread_id <> PS_CURRENT_THREAD_ID()) = 0 DO
    SET tries = tries + 1;
    IF tries > 100 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'other session never took its lock';
    END IF;
    DO SLEEP(0.1);
  END WHILE;
END$$

-- Waits until no other session has an open InnoDB transaction.
CREATE PROCEDURE wait_idle()
BEGIN
  DECLARE tries INT DEFAULT 0;
  WHILE (SELECT COUNT(*) FROM information_schema.innodb_trx
         WHERE trx_mysql_thread_id <> CONNECTION_ID()) > 0 DO
    SET tries = tries + 1;
    IF tries > 150 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'other session never finished';
    END IF;
    DO SLEEP(0.1);
  END WHILE;
END$$

-- 1. Worker 1 claims a batch with SKIP LOCKED and keeps its transaction open.
CREATE EVENT worker1_claims ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  START TRANSACTION;
  SELECT GROUP_CONCAT(id) INTO @ids FROM (
    SELECT id FROM jobs WHERE status = 'queued' ORDER BY id LIMIT 10
    FOR UPDATE SKIP LOCKED
  ) AS next;
  SET @claim = CONCAT('UPDATE jobs SET status = ''running'', worker = 1 WHERE id IN (', @ids, ')');
  PREPARE claim FROM @claim;
  EXECUTE claim;
  DEALLOCATE PREPARE claim;
  DO SLEEP(5);
  COMMIT;
END$$

DELIMITER ;

CALL wait_for_lock('jobs');

-- Worker 2 (this session) claims the next batch without waiting for worker 1.
-- 1 s keeps the example fast; pick your production value per session.
SET SESSION innodb_lock_wait_timeout = 1;
SET SESSION lock_wait_timeout = 1;
START TRANSACTION;
SELECT GROUP_CONCAT(id) INTO @ids FROM (
  SELECT id FROM jobs WHERE status = 'queued' ORDER BY id LIMIT 10
  FOR UPDATE SKIP LOCKED
) AS next;
-- The application gets the ids back and sends the UPDATE with that list.
SET @claim = CONCAT('UPDATE jobs SET status = ''running'', worker = 2 WHERE id IN (', @ids, ')');
PREPARE claim FROM @claim;
EXECUTE claim;
DEALLOCATE PREPARE claim;
-- A row someone else holds: fail fast instead of queueing behind them.
CALL assert_errno('SELECT id FROM jobs WHERE id = 1 FOR UPDATE NOWAIT', 3572, 'NOWAIT fails at once on a held row');
COMMIT;


-- 2. A lock wait timeout rolls back only the statement: roll back the rest.
START TRANSACTION;
INSERT INTO audit_log (msg) VALUES ('cancel job 1');
CALL assert_errno("UPDATE jobs SET status = 'cancelled' WHERE id = 1", 1205, 'innodb_lock_wait_timeout bounds the row lock wait');
-- 1205 undid the UPDATE only; ROLLBACK undoes the INSERT too, then retry it all.
ROLLBACK;
CALL assert_true((SELECT COUNT(*) FROM audit_log) = 0, 'no half of the transaction was committed');

-- DDL waits on the metadata lock of worker 1's open transaction; the default
-- lock_wait_timeout is a year, the session value here is 1 s.
CALL assert_errno('ALTER TABLE jobs ADD COLUMN note VARCHAR(10)', 1205, 'lock_wait_timeout bounds the metadata lock wait');

CALL wait_idle();
CALL assert_true((SELECT COUNT(*) FROM jobs WHERE worker = 2) = 10, 'worker 2 claimed 10 jobs while worker 1 held its batch');
CALL assert_true((SELECT MIN(id) FROM jobs WHERE worker = 2) = 11, 'worker 2 skipped the 10 locked jobs');
CALL assert_true((SELECT COUNT(*) FROM jobs WHERE worker = 1) = 10, 'worker 1 batch committed');
CALL assert_true((SELECT COUNT(*) FROM jobs WHERE status = 'running') = 20, 'no job claimed twice');

-- 3. READ COMMITTED: a locking read on a range locks the matching rows only.
DELIMITER $$
CREATE EVENT rc_range_lock ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  SET SESSION transaction_isolation = 'READ-COMMITTED';
  START TRANSACTION;
  SELECT COUNT(*) INTO @n FROM orders WHERE account_id = 10 FOR UPDATE;
  DO SLEEP(3);
  COMMIT;
END$$
DELIMITER ;

CALL wait_for_lock('orders');
-- Account 11 falls in the gap after account 10, and the insert goes through.
INSERT INTO orders (account_id, amount) VALUES (11, 50);
-- Read into a variable: a subquery passed to CALL takes shared row locks.
SELECT COUNT(*) INTO @inserted FROM orders WHERE account_id = 11;
CALL assert_true(@inserted = 1, 'insert into the gap did not wait under READ COMMITTED');
-- The rows that matched are still locked.
CALL assert_errno('UPDATE orders SET amount = 0 WHERE account_id = 10', 1205, 'matching rows stay locked under READ COMMITTED');
CALL wait_idle();

-- 4. Both transactions lock accounts in id order, so one waits and none deadlocks.
DELIMITER $$
CREATE EVENT transfer_1_to_2 ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  START TRANSACTION;
  SELECT COUNT(*) INTO @n FROM accounts WHERE id IN (1, 2) ORDER BY id FOR UPDATE;
  UPDATE accounts SET balance = balance - 10 WHERE id = 1;
  DO SLEEP(2);
  UPDATE accounts SET balance = balance + 10 WHERE id = 2;
  COMMIT;
END$$
DELIMITER ;

CALL wait_for_lock('accounts');
SET SESSION innodb_lock_wait_timeout = 5;
SELECT count AS deadlocks_before FROM information_schema.innodb_metrics WHERE name = 'lock_deadlocks' INTO @deadlocks_before;
START TRANSACTION;
SELECT id FROM accounts WHERE id IN (1, 2) ORDER BY id FOR UPDATE;
UPDATE accounts SET balance = balance - 20 WHERE id = 2;
UPDATE accounts SET balance = balance + 20 WHERE id = 1;
COMMIT;

CALL assert_true((SELECT balance FROM accounts WHERE id = 1) = 110, 'account 1: -10 then +20');
CALL assert_true((SELECT balance FROM accounts WHERE id = 2) = 90, 'account 2: +10 then -20');
CALL assert_true((SELECT count FROM information_schema.innodb_metrics WHERE name = 'lock_deadlocks') = @deadlocks_before, 'consistent lock order: no deadlock');

CALL wait_idle();
DROP EVENT IF EXISTS worker1_claims;
DROP EVENT IF EXISTS rc_range_lock;
DROP EVENT IF EXISTS transfer_1_to_2;
