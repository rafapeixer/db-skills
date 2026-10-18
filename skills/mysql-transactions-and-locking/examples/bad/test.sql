-- Bad: the defaults left alone (REPEATABLE READ, a 50 s row lock wait, a
-- one-year metadata lock wait), a queue claimed with plain FOR UPDATE, COMMIT
-- after a lock wait timeout, rows locked in opposite orders with a
-- statement-only "retry", and autocommit turned off and forgotten. The second
-- session is an event: the event scheduler runs it in its own connection.
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

-- Waits until another session has an open InnoDB transaction.
CREATE PROCEDURE wait_for_trx()
BEGIN
  DECLARE tries INT DEFAULT 0;
  WHILE (SELECT COUNT(*) FROM information_schema.innodb_trx
         WHERE trx_mysql_thread_id <> CONNECTION_ID()) = 0 DO
    SET tries = tries + 1;
    IF tries > 100 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'other session never opened a transaction';
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

-- Many small autocommit updates, one transaction (and one undo log) each.
CREATE PROCEDURE touch_orders(IN n INT)
BEGIN
  DECLARE i INT DEFAULT 1;
  WHILE i <= n DO
    UPDATE orders SET amount = amount + 1 WHERE id = i;
    SET i = i + 1;
  END WHILE;
END$$

DELIMITER ;

-- MISTAKE: nothing is set per session, so every lock wait runs on the defaults.
CALL assert_true(@@transaction_isolation = 'REPEATABLE-READ', 'default isolation is REPEATABLE READ');
CALL assert_true(@@innodb_lock_wait_timeout = 50, 'a row lock wait can last 50 s');
CALL assert_true(@@lock_wait_timeout = 31536000, 'a metadata lock wait can last a year');
CALL assert_true(@@innodb_rollback_on_timeout = 0, 'a lock wait timeout rolls back only the statement');

-- 1. Worker 1 claims a batch with plain FOR UPDATE and keeps it open.
DELIMITER $$
CREATE EVENT worker1_claims ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  START TRANSACTION;
  SELECT GROUP_CONCAT(id) INTO @ids FROM (
    SELECT id FROM jobs WHERE status = 'queued' ORDER BY id LIMIT 10 FOR UPDATE
  ) AS next;
  UPDATE jobs SET status = 'running', worker = 1 WHERE id <= 10;
  DO SLEEP(5);
  COMMIT;
END$$
DELIMITER ;

CALL wait_for_lock('jobs');
-- 1 s only so the example does not hang; with the default this waits 50 s.
SET SESSION innodb_lock_wait_timeout = 1;
-- MISTAKE: no SKIP LOCKED, so worker 2 queues behind worker 1's rows.
CALL assert_errno("SELECT id FROM jobs WHERE status = 'queued' ORDER BY id LIMIT 10 FOR UPDATE", 1205, 'worker 2 waits on worker 1 rows');

-- 2. MISTAKE: the lock wait timeout undid only the UPDATE, and the
-- application commits anyway: the audit row says job 1 was cancelled.
START TRANSACTION;
INSERT INTO audit_log (msg) VALUES ('cancel job 1');
CALL assert_errno("UPDATE jobs SET status = 'cancelled' WHERE id = 1", 1205, 'the UPDATE timed out');
CALL assert_true((SELECT COUNT(*) FROM information_schema.innodb_trx WHERE trx_mysql_thread_id = CONNECTION_ID()) = 1, 'the transaction is still open after 1205');
COMMIT;
CALL wait_idle();
CALL assert_true((SELECT COUNT(*) FROM audit_log WHERE msg = 'cancel job 1') = 1, 'half of the transaction was committed');
CALL assert_true((SELECT status FROM jobs WHERE id = 1) = 'running', 'the job was never cancelled');

-- 3. REPEATABLE READ: a locking read of one account locks the gap after it.
DELIMITER $$
CREATE EVENT rr_range_lock ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  START TRANSACTION;
  SELECT COUNT(*) INTO @n FROM orders WHERE account_id = 10 FOR UPDATE;
  DO SLEEP(3);
  COMMIT;
END$$
DELIMITER ;

CALL wait_for_lock('orders');
-- MISTAKE: a hot path locks a range under REPEATABLE READ; account 11's
-- insert falls in the gap after account 10 and waits for that transaction.
CALL assert_errno('INSERT INTO orders (account_id, amount) VALUES (11, 50)', 1205, 'insert for another account blocked by a gap lock');
CALL wait_idle();

-- 4. Opposite lock order. Worker 1 (the bigger transaction) moves 10 from
-- account 1 to 2; this session moves 20 from 2 to 1.
DELIMITER $$
CREATE EVENT transfer_1_to_2 ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  START TRANSACTION;
  UPDATE jobs SET payload = CONCAT(payload, '.') WHERE id <= 200;
  UPDATE accounts SET balance = balance - 10 WHERE id = 1;
  DO SLEEP(2);
  UPDATE accounts SET balance = balance + 10 WHERE id = 2;
  COMMIT;
END$$
DELIMITER ;

CALL wait_for_lock('accounts');
SET SESSION innodb_lock_wait_timeout = 10;
START TRANSACTION;
INSERT INTO audit_log (msg) VALUES ('transfer 20 from 2 to 1');
-- MISTAKE: account 2 first, while the other transaction locks account 1 first.
UPDATE accounts SET balance = balance - 20 WHERE id = 2;
CALL assert_errno('UPDATE accounts SET balance = balance + 20 WHERE id = 1', 1213, 'opposite lock order deadlocks');
CALL assert_true((SELECT COUNT(*) FROM information_schema.innodb_trx WHERE trx_mysql_thread_id = CONNECTION_ID()) = 0, 'the deadlock rolled back the whole transaction');
-- MISTAKE: the "retry" re-sends only the failed statement. The debit and the
-- audit row were rolled back with the transaction, so 20 appears from nowhere.
UPDATE accounts SET balance = balance + 20 WHERE id = 1;
COMMIT;
CALL wait_idle();
CALL assert_true((SELECT SUM(balance) FROM accounts) = 220, 'money created: credit without debit');
CALL assert_true((SELECT COUNT(*) FROM audit_log WHERE msg LIKE 'transfer%') = 0, 'audit row lost');

-- 5. MISTAKE: autocommit turned off and a SELECT never committed. The read
-- view stays open and purge cannot remove any undo written after it.
DELIMITER $$
CREATE EVENT forgotten_select ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  SET autocommit = 0;
  SELECT COUNT(*) INTO @n FROM jobs;
  -- Held long enough for slow CI disks; killed below once measured.
  DO SLEEP(120);
END$$
DELIMITER ;

CALL wait_for_trx();
CALL touch_orders(1000);
SELECT count INTO @history_after FROM information_schema.innodb_metrics WHERE name = 'trx_rseg_history_len';
-- Every update committed after the open read view stays in the history list.
CALL assert_true(@history_after >= 900, 'purge cannot remove updates newer than the open read view');

-- End the forgotten session instead of waiting out its sleep.
SELECT CONCAT('KILL ', trx_mysql_thread_id) INTO @kill FROM information_schema.innodb_trx
  WHERE trx_mysql_thread_id <> CONNECTION_ID() LIMIT 1;
PREPARE k FROM @kill;
EXECUTE k;
DEALLOCATE PREPARE k;

CALL wait_idle();
DROP EVENT IF EXISTS worker1_claims;
DROP EVENT IF EXISTS rr_range_lock;
DROP EVENT IF EXISTS transfer_1_to_2;
DROP EVENT IF EXISTS forgotten_select;
