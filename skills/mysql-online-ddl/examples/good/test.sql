-- Schema changes on a table that is serving traffic. Every ALTER names its
-- ALGORITHM (and LOCK for INPLACE), so MySQL refuses instead of copying the
-- table, and every ALTER runs with a short lock_wait_timeout and a retry.

CREATE TABLE orders (
  id          INT PRIMARY KEY,
  customer_id INT NOT NULL,
  amount      INT NOT NULL,
  note        VARCHAR(50)
) CHARSET utf8mb4;
INSERT INTO orders (id, customer_id, amount, note)
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20000)
SELECT n, n % 2000, n % 500, CONCAT('order ', n) FROM seq;
ANALYZE TABLE orders;

-- TABLE_ID and SPACE change when InnoDB rebuilds or copies the table.
CREATE FUNCTION innodb_table_id(tbl VARCHAR(64)) RETURNS BIGINT READS SQL DATA
  RETURN (SELECT TABLE_ID FROM information_schema.INNODB_TABLES WHERE NAME = CONCAT(DATABASE(), '/', tbl));
CREATE FUNCTION innodb_space(tbl VARCHAR(64)) RETURNS BIGINT READS SQL DATA
  RETURN (SELECT SPACE FROM information_schema.INNODB_TABLES WHERE NAME = CONCAT(DATABASE(), '/', tbl));
CREATE FUNCTION row_versions(tbl VARCHAR(64)) RETURNS INT READS SQL DATA
  RETURN (SELECT TOTAL_ROW_VERSIONS FROM information_schema.INNODB_TABLES WHERE NAME = CONCAT(DATABASE(), '/', tbl));

SET @orders_id = innodb_table_id('orders');
SET @orders_space = innodb_space('orders');

-- 1. ADD COLUMN with ALGORITHM=INSTANT: only metadata changes.
-- INSTANT accepts no LOCK clause other than DEFAULT.
CALL assert_true(row_versions('orders') < 64, 'room for another instant row version');
ALTER TABLE orders ADD COLUMN status TINYINT NOT NULL DEFAULT 0, ALGORITHM=INSTANT;
CALL assert_true(innodb_table_id('orders') = @orders_id AND innodb_space('orders') = @orders_space,
  'INSTANT kept the same table and tablespace');
CALL assert_true(row_versions('orders') = 1, 'INSTANT ADD COLUMN added one row version');
CALL assert_error('ALTER TABLE orders ADD COLUMN source INT, ALGORITHM=INSTANT, LOCK=NONE',
  'HY000', 'INSTANT rejects LOCK=NONE (error 1221)');

-- 2. A type change cannot be done INSTANT or INPLACE. Naming the algorithm
-- turns the silent table copy into an error (1846, SQLSTATE 0A000).
CALL assert_error('ALTER TABLE orders MODIFY amount BIGINT NOT NULL, ALGORITHM=INSTANT',
  '0A000', 'type change refused as INSTANT');
CALL assert_error('ALTER TABLE orders MODIFY amount BIGINT NOT NULL, ALGORITHM=INPLACE, LOCK=NONE',
  '0A000', 'type change refused as INPLACE');
CALL assert_true(innodb_table_id('orders') = @orders_id, 'the refused ALTER copied nothing');

-- VARCHAR can grow in place only while it keeps the same length bytes:
-- utf8mb4 is 4 bytes per character, so 63 characters is 252 bytes (1 length
-- byte) and 64 characters is 256 bytes (2 length bytes).
ALTER TABLE orders MODIFY note VARCHAR(63), ALGORITHM=INPLACE, LOCK=NONE;
CALL assert_error('ALTER TABLE orders MODIFY note VARCHAR(64), ALGORITHM=INPLACE, LOCK=NONE',
  '0A000', 'crossing 255 bytes needs a copy');
CALL assert_true(innodb_table_id('orders') = @orders_id, 'VARCHAR(63) did not rebuild');

-- 3. Secondary indexes: INPLACE with LOCK=NONE, no rebuild, DML continues.
CALL assert_error('ALTER TABLE orders ADD INDEX idx_orders_customer (customer_id), ALGORITHM=INSTANT',
  '0A000', 'an index build is never INSTANT');
ALTER TABLE orders ADD INDEX idx_orders_customer (customer_id), ALGORITHM=INPLACE, LOCK=NONE;
CALL assert_true(innodb_table_id('orders') = @orders_id, 'index build did not rebuild the table');
EXPLAIN FORMAT=JSON INTO @plan SELECT id FROM orders WHERE customer_id = 42;
CALL assert_true(plan_has(@plan, 'idx_orders_customer'), 'lookup uses the new index');

-- 4. Retire an index: make it INVISIBLE, watch production, drop it later.
ALTER TABLE orders ALTER INDEX idx_orders_customer INVISIBLE, ALGORITHM=INPLACE, LOCK=NONE;
EXPLAIN FORMAT=JSON INTO @plan SELECT id FROM orders WHERE customer_id = 42;
CALL assert_true(NOT plan_has(@plan, 'idx_orders_customer'), 'optimizer ignores the invisible index');
CALL assert_true(plan_has(@plan, 'ALL') OR plan_has(@plan, 'table'), 'the lookup is now a full scan');
-- Undo is instant if a query regresses; the index was maintained all along.
ALTER TABLE orders ALTER INDEX idx_orders_customer VISIBLE, ALGORITHM=INPLACE, LOCK=NONE;
ALTER TABLE orders ALTER INDEX idx_orders_customer INVISIBLE, ALGORITHM=INPLACE, LOCK=NONE;
ALTER TABLE orders DROP INDEX idx_orders_customer, ALGORITHM=INPLACE, LOCK=NONE;
CALL assert_true(innodb_table_id('orders') = @orders_id, 'visibility and drop did not rebuild');

-- 5. Row versions are capped: 64 on 8.4, 255 from 9.1.0. At the cap an
-- explicit ALGORITHM=INSTANT fails with error 4092 instead of rebuilding.
CREATE TABLE churn (id INT PRIMARY KEY);
DELIMITER $$
CREATE PROCEDURE instant_until_refused(OUT done INT, OUT errno INT)
BEGIN
  DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 errno = MYSQL_ERRNO;
  SET done = 0, errno = NULL;
  WHILE errno IS NULL AND done < 300 DO
    SET @ddl = IF(done % 2 = 0, 'ALTER TABLE churn ADD COLUMN x INT, ALGORITHM=INSTANT',
                                'ALTER TABLE churn DROP COLUMN x, ALGORITHM=INSTANT');
    PREPARE s FROM @ddl;
    EXECUTE s;
    DEALLOCATE PREPARE s;
    IF errno IS NULL THEN SET done = done + 1; END IF;
  END WHILE;
END$$
DELIMITER ;
SET @churn_id = innodb_table_id('churn');
CALL instant_until_refused(@done, @errno);
CALL assert_true(@done = IF(VERSION() LIKE '8.%', 64, 255), 'row version cap: 64 on 8.4, 255 on 9.x');
CALL assert_true(@errno = 4092, 'INSTANT at the cap fails with 4092');
CALL assert_true(innodb_table_id('churn') = @churn_id, 'and nothing was rebuilt behind your back');

-- 6. Metadata locks. Another session (an event) holds a transaction that
-- has read orders, so it holds a shared metadata lock until it commits. It
-- stays open until the migration runner below has timed out once, so the
-- test does not depend on how fast the machine is.
CREATE TABLE ddl_log (attempt INT NOT NULL, outcome VARCHAR(20) NOT NULL);
-- Events report progress here, always after their own COMMIT.
CREATE TABLE steps (name VARCHAR(40) PRIMARY KEY);
DELIMITER $$
-- Waits (up to 60 s) until an event has taken its '<name> parked' user lock,
-- which it does once it holds what the test needs it to hold.
CREATE PROCEDURE wait_for_parked(IN gate VARCHAR(30))
BEGIN
  DECLARE tries INT DEFAULT 0;
  WHILE IS_USED_LOCK(CONCAT(DATABASE(), '.', gate, ' parked')) IS NULL DO
    SET tries = tries + 1;
    IF tries > 600 THEN
      SET @wait_msg = LEFT(CONCAT('never parked: ', gate), 128);
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = @wait_msg;
    END IF;
    DO SLEEP(0.1);
  END WHILE;
END$$

-- Waits (up to 60 s) until an event has recorded a step.
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

-- The migration runner: short lock wait, retry on 1205 with a pause, and a
-- log row per attempt.
CREATE PROCEDURE ddl_with_retry(IN stmt TEXT, IN max_attempts INT, OUT attempts INT)
BEGIN
  DECLARE timed_out BOOLEAN DEFAULT FALSE;
  DECLARE CONTINUE HANDLER FOR 1205 SET timed_out = TRUE;
  SET attempts = 0;
  retry: LOOP
    SET attempts = attempts + 1, timed_out = FALSE;
    SET SESSION lock_wait_timeout = 1;
    SET @ddl = stmt;
    PREPARE s FROM @ddl;
    IF NOT timed_out THEN
      EXECUTE s;
      DEALLOCATE PREPARE s;
    END IF;
    INSERT INTO ddl_log VALUES (attempts, IF(timed_out, 'timed out', 'done'));
    IF NOT timed_out OR attempts >= max_attempts THEN LEAVE retry; END IF;
    DO SLEEP(1);
  END LOOP;
  IF timed_out THEN
    SIGNAL SQLSTATE 'HY000' SET MESSAGE_TEXT = 'DDL gave up after all retries';
  END IF;
END$$
DELIMITER ;

SET GLOBAL event_scheduler = ON;
DELIMITER $$
CREATE EVENT hold ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  DECLARE tries INT DEFAULT 0;
  -- READ COMMITTED only so the loop below sees new ddl_log rows.
  SET SESSION transaction_isolation = 'READ-COMMITTED';
  START TRANSACTION;
  SELECT COUNT(*) INTO @x FROM orders;
  DO GET_LOCK(CONCAT(DATABASE(), '.hold parked'), 0);
  -- Open until the runner logs a timed-out attempt (at most 120 s).
  WHILE NOT EXISTS (SELECT 1 FROM ddl_log WHERE outcome = 'timed out') AND tries < 1200 DO
    SET tries = tries + 1;
    DO SLEEP(0.1);
  END WHILE;
  COMMIT;
  INSERT INTO steps VALUES ('hold committed');
END$$
DELIMITER ;
CALL wait_for_parked('hold');

SET SESSION lock_wait_timeout = 1;
CALL assert_error('ALTER TABLE orders ADD COLUMN shipped_at DATETIME NULL, ALGORITHM=INSTANT',
  'HY000', 'ALTER gives up after 1s (error 1205) instead of queueing in front of traffic');
-- Because the ALTER gave up, reads are not stuck behind it.
SELECT COUNT(*) INTO @n FROM orders WHERE id = 1;
CALL assert_true(@n = 1, 'a read still runs while the long transaction is open');

CALL ddl_with_retry('ALTER TABLE orders ADD COLUMN shipped_at DATETIME NULL, ALGORITHM=INSTANT', 10, @attempts);
CALL assert_true(@attempts > 1, 'the first attempt timed out and a retry succeeded');
CALL assert_true((SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'orders' AND COLUMN_NAME = 'shipped_at') = 1,
  'column added after the long transaction committed');
CALL assert_true(innodb_table_id('orders') = @orders_id, 'still the original table: no copy all along');

CALL wait_for_step('hold committed');
CALL cleanup_sessions();
DROP EVENT IF EXISTS hold;
