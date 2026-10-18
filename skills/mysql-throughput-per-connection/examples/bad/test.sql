-- Bad: every request holds its connection longer than it needs to. A page
-- that sends one query per order, one commit per row, a queue claimed under
-- REPEATABLE READ or with plain FOR UPDATE and worked on inside the
-- transaction, and a counter every request updates, or sharded with the
-- shard picked by RAND() inside the statement. Other sessions are events,
-- gated by user locks (GET_LOCK) this session holds, so they move only when
-- this session lets them, however slow the machine is.
SET GLOBAL event_scheduler = ON;

-- 500 customers with 40 orders each, 3 items per order.
CREATE TABLE orders (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  customer_id BIGINT NOT NULL,
  total DECIMAL(12, 2) NOT NULL,
  created_at DATETIME(6) NOT NULL,
  KEY orders_customer_created (customer_id, created_at DESC, id DESC)
);
INSERT INTO orders (customer_id, total, created_at)
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20000)
SELECT 1 + n % 500, 10.00, '2026-01-01' + INTERVAL n MINUTE FROM seq;
CREATE TABLE order_items (
  order_id BIGINT NOT NULL,
  sku VARCHAR(40) NOT NULL,
  qty INT NOT NULL,
  PRIMARY KEY (order_id, sku)
);
INSERT INTO order_items
SELECT id, 'A1', 1 FROM orders UNION ALL SELECT id, 'B1', 2 FROM orders UNION ALL SELECT id, 'C1', 3 FROM orders;

CREATE TABLE jobs (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  claimed_at DATETIME(6) NULL,
  KEY jobs_status_id (status, id)
);
INSERT INTO jobs (status)
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000)
SELECT 'pending' FROM seq;

CREATE TABLE stock (sku VARCHAR(40) PRIMARY KEY, qty BIGINT NOT NULL);
INSERT INTO stock VALUES ('SKU-1', 16000);
CREATE TABLE stock_shards (
  sku VARCHAR(40) NOT NULL,
  shard INT NOT NULL,
  qty BIGINT NOT NULL,
  PRIMARY KEY (sku, shard)
);
INSERT INTO stock_shards
WITH RECURSIVE seq (n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < 15)
SELECT 'SKU-1', n, 1000 FROM seq;

CREATE TABLE sale_lines (id BIGINT AUTO_INCREMENT PRIMARY KEY, sku VARCHAR(40) NOT NULL, qty INT NOT NULL);
-- Events report progress here, always after their own COMMIT.
CREATE TABLE steps (name VARCHAR(40) PRIMARY KEY, conn BIGINT NULL, val BIGINT NULL);
ANALYZE TABLE orders, order_items, jobs, stock, stock_shards;

DELIMITER $$

-- assert_errno is assert_error keyed on the MySQL error number, because a
-- lock wait timeout (1205) shares SQLSTATE HY000 with many other errors.
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

-- Waits (up to 60 s) until an event has recorded a step. Call it only in
-- autocommit or under READ COMMITTED, so each check sees new rows.
CREATE PROCEDURE wait_for_step(IN step VARCHAR(40))
BEGIN
  DECLARE tries INT DEFAULT 0;
  WHILE (SELECT COUNT(*) FROM steps WHERE name = step) = 0 DO
    SET tries = tries + 1;
    IF tries > 600 THEN
      SET @wait_msg = LEFT(CONCAT('never happened: ', step), 128);
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = @wait_msg;
    END IF;
    DO SLEEP(0.1);
  END WHILE;
END$$

-- Waits (up to 60 s) until another session holds a row lock on the table.
CREATE PROCEDURE wait_for_lock(IN tbl VARCHAR(64))
BEGIN
  DECLARE tries INT DEFAULT 0;
  WHILE (SELECT COUNT(*) FROM performance_schema.data_locks
         WHERE object_schema = DATABASE() AND object_name = tbl
           AND lock_type = 'RECORD' AND thread_id <> PS_CURRENT_THREAD_ID()) = 0 DO
    SET tries = tries + 1;
    IF tries > 600 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'other session never took its lock';
    END IF;
    DO SLEEP(0.1);
  END WHILE;
END$$

-- Waits (up to 60 s) until some transaction in this database waits on a
-- row lock, and returns the lock mode it is waiting for.
CREATE PROCEDURE wait_for_lock_wait(OUT waiting_mode VARCHAR(64), OUT waiting_index VARCHAR(64))
BEGIN
  DECLARE tries INT DEFAULT 0;
  SET waiting_mode = NULL;
  WHILE waiting_mode IS NULL DO
    SELECT MAX(r.LOCK_MODE), MAX(r.INDEX_NAME) INTO waiting_mode, waiting_index
    FROM performance_schema.data_lock_waits AS w
    JOIN performance_schema.data_locks AS r ON r.ENGINE_LOCK_ID = w.REQUESTING_ENGINE_LOCK_ID
    WHERE r.OBJECT_SCHEMA = DATABASE();
    IF waiting_mode IS NULL THEN
      SET tries = tries + 1;
      IF tries > 600 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no session ever waited on a lock';
      END IF;
      DO SLEEP(0.1);
    END IF;
  END WHILE;
END$$

-- Kills any event session still connected to this database, so a failed
-- run never leaves a session holding locks.
CREATE PROCEDURE cleanup_sessions()
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE pid BIGINT;
  DECLARE c CURSOR FOR SELECT id FROM performance_schema.processlist
    WHERE db = DATABASE() AND id <> CONNECTION_ID();
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
  DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
  OPEN c;
  sessions: LOOP
    FETCH c INTO pid;
    IF done THEN LEAVE sessions; END IF;
    KILL pid;
  END LOOP;
  CLOSE c;
END$$

-- One sale line per INSERT, the way an application loop would send them.
CREATE PROCEDURE record_sales(IN n INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  WHILE i < n DO
    INSERT INTO sale_lines (sku, qty) VALUES ('SKU-1', 1);
    SET i = i + 1;
  END WHILE;
END$$

-- n sales with the shard picked inside the statement, counting the
-- statements that did not change exactly one shard.
CREATE PROCEDURE sell_random_in_where(IN n INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  DECLARE changed INT;
  SET @wrong = 0, @changed = 0;
  WHILE i < n DO
    -- MISTAKE: RAND() is evaluated for every row the UPDATE reads, even
    -- inside a scalar subquery, so one sale changes zero, one or several shards.
    UPDATE stock_shards SET qty = qty - 1 WHERE sku = 'SKU-1' AND shard = (SELECT FLOOR(RAND() * 16));
    SET changed = ROW_COUNT();
    SET @changed = @changed + changed;
    IF changed <> 1 THEN SET @wrong = @wrong + 1; END IF;
    SET i = i + 1;
  END WHILE;
END$$

DELIMITER ;

-- 1. N+1: the page, then one query per order it returned.
SELECT id FROM orders WHERE customer_id = 7 ORDER BY created_at DESC, id DESC LIMIT 10;
CALL assert_true((SELECT GROUP_CONCAT(id ORDER BY created_at DESC, id DESC) FROM (
  SELECT id, created_at FROM orders WHERE customer_id = 7 ORDER BY created_at DESC, id DESC LIMIT 10) AS page)
  = '19506,19006,18506,18006,17506,17006,16506,16006,15506,15006', 'the page returned these 10 order ids');
-- MISTAKE: one query per order. 10 orders cost 11 round trips; in the
-- benchmark this page served 138 requests/s per connection against 1,277.
SELECT sku, qty FROM order_items WHERE order_id = 19506;
SELECT sku, qty FROM order_items WHERE order_id = 19006;
SELECT sku, qty FROM order_items WHERE order_id = 18506;
SELECT sku, qty FROM order_items WHERE order_id = 18006;
SELECT sku, qty FROM order_items WHERE order_id = 17506;
SELECT sku, qty FROM order_items WHERE order_id = 17006;
SELECT sku, qty FROM order_items WHERE order_id = 16506;
SELECT sku, qty FROM order_items WHERE order_id = 16006;
SELECT sku, qty FROM order_items WHERE order_id = 15506;
SELECT sku, qty FROM order_items WHERE order_id = 15006;

-- Every query is fast (a primary key lookup); the cost is the count.
CALL assert_true((SELECT COUNT_STAR FROM performance_schema.events_statements_summary_by_digest
                  WHERE SCHEMA_NAME = DATABASE() AND DIGEST_TEXT LIKE 'SELECT `id` FROM `orders` WHERE `customer_id` = ?%') = 1
             AND (SELECT COUNT_STAR FROM performance_schema.events_statements_summary_by_digest
                  WHERE SCHEMA_NAME = DATABASE() AND DIGEST_TEXT LIKE 'SELECT `sku` , `qty` FROM `order_items` WHERE `order_id` = ?%') = 10,
                 'the page with its items is 11 statements');

-- 2. MISTAKE: one commit per row. Each autocommit INSERT waits for its own
-- redo log and binary log flush; the round trips are the same as one
-- transaction, the commits are 200 times more.
SELECT VARIABLE_VALUE INTO @fsyncs FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_os_log_fsyncs';
CALL record_sales(200);
SELECT VARIABLE_VALUE - @fsyncs INTO @fsyncs FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_os_log_fsyncs';
CALL assert_true(@fsyncs >= 200, 'at least one redo log fsync per row');

-- 3. Queue under the default REPEATABLE READ. Worker 2 waits on the 'start'
-- lock until worker 1 (this session) holds its claim.
SET @start = CONCAT(DATABASE(), '.start');
CALL assert_true(GET_LOCK(@start, 0) = 1, 'this session holds the start gate');
DELIMITER $$
CREATE EVENT worker2_rr ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  IF GET_LOCK(CONCAT(DATABASE(), '.start'), 120) = 1 THEN
    -- Long enough never to time out on a slow machine: this session ends the wait.
    SET SESSION innodb_lock_wait_timeout = 120;
    START TRANSACTION;
    SELECT id INTO @id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED;
    UPDATE jobs SET status = 'done', claimed_at = NOW(6) WHERE id = @id;
    COMMIT;
    INSERT INTO steps VALUES ('worker 2 done', CONNECTION_ID(), @id);
  END IF;
END$$
DELIMITER ;

CALL assert_true(@@SESSION.transaction_isolation = 'REPEATABLE-READ', 'the session runs on the default isolation level');
-- MISTAKE: under REPEATABLE READ the claim takes a next-key lock, which also
-- locks the gap before the row. Moving a job from 'pending' to 'done' inserts
-- into that gap, so worker 2's UPDATE waits for worker 1 to commit.
START TRANSACTION;
SELECT id INTO @job FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED;
UPDATE jobs SET status = 'done', claimed_at = NOW(6) WHERE id = @job;
DO RELEASE_LOCK(@start);
CALL wait_for_lock_wait(@mode, @index);
CALL assert_true(@mode = 'X,GAP,INSERT_INTENTION' AND @index = 'jobs_status_id',
                 'worker 2 waits for an insert intention lock on the gap worker 1 locked');
COMMIT;
CALL wait_for_step('worker 2 done');
CALL assert_true(@job = 1 AND (SELECT val FROM steps WHERE name = 'worker 2 done') = 2,
                 'SKIP LOCKED gave worker 2 another job, and its UPDATE still queued behind worker 1');

-- 4. Plain FOR UPDATE with the work inside the transaction.
SET @work = CONCAT(DATABASE(), '.work');
CALL assert_true(GET_LOCK(@work, 0) = 1, 'this session holds the work gate');
DELIMITER $$
CREATE EVENT worker1_for_update ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  START TRANSACTION;
  SELECT id INTO @id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE;
  UPDATE jobs SET status = 'running', claimed_at = NOW(6) WHERE id = @id;
  -- The job runs here, inside the transaction, holding the row lock.
  DO GET_LOCK(CONCAT(DATABASE(), '.work'), 120);
  UPDATE jobs SET status = 'done' WHERE id = @id;
  COMMIT;
  INSERT INTO steps VALUES ('worker 1 done', CONNECTION_ID(), @id);
END$$
DELIMITER ;

CALL wait_for_lock('jobs');
CALL assert_true((SELECT COUNT(*) FROM information_schema.innodb_trx
                  WHERE trx_mysql_thread_id <> CONNECTION_ID() AND trx_rows_locked > 0) = 1,
                 'worker 1 holds an open transaction and its row locks while it works');
-- 1 s only so the test does not hang; in production worker 2 waits 50 s by default.
SET SESSION innodb_lock_wait_timeout = 1;
-- MISTAKE: no SKIP LOCKED, so worker 2 queues behind worker 1's row for as
-- long as worker 1's job takes.
CALL assert_errno("SELECT id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE", 1205, 'worker 2 waits on the row worker 1 is working on');
DO RELEASE_LOCK(@work);
CALL wait_for_step('worker 1 done');

-- 5. A hot row: every sale updates the same row.
SET @hold = CONCAT(DATABASE(), '.hold');
CALL assert_true(GET_LOCK(@hold, 0) = 1, 'this session holds the hold gate');
DELIMITER $$
CREATE EVENT sale_on_hot_row ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  START TRANSACTION;
  UPDATE stock SET qty = qty - 1 WHERE sku = 'SKU-1';
  DO GET_LOCK(CONCAT(DATABASE(), '.hold'), 120);
  COMMIT;
  INSERT INTO steps VALUES ('hot row sold', CONNECTION_ID(), NULL);
END$$
DELIMITER ;

CALL wait_for_lock('stock');
-- MISTAKE: one row for every request. The row lock lasts until the sale
-- commits, so concurrent sales run one at a time; in the benchmark this row
-- stayed at about 515 updates/s from 4 to 64 connections.
CALL assert_errno("UPDATE stock SET qty = qty - 1 WHERE sku = 'SKU-1'", 1205, 'a second sale waits for the first to commit');
DO RELEASE_LOCK(@hold);
CALL wait_for_step('hot row sold');
SET SESSION innodb_lock_wait_timeout = 50;

-- 6. Shards picked by RAND() inside the statement.
CALL sell_random_in_where(300);
CALL assert_true(@wrong > 0, 'some sales changed zero or several shards');
CALL assert_true((SELECT SUM(qty) FROM stock_shards WHERE sku = 'SKU-1') = 16000 - @changed,
                 'the total moved by the rows changed, not by the 300 sales');

CALL cleanup_sessions();
DROP EVENT IF EXISTS worker2_rr;
DROP EVENT IF EXISTS worker1_for_update;
DROP EVENT IF EXISTS sale_on_hot_row;
