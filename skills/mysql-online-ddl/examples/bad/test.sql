-- Schema changes written as if the table were idle. Each assertion below
-- describes the bad outcome, so this file fails if a mistake stops showing.

CREATE TABLE orders (
  id          INT PRIMARY KEY,
  customer_id INT NOT NULL,
  amount      INT NOT NULL,
  note        VARCHAR(50),
  KEY idx_orders_customer (customer_id)
) CHARSET utf8mb4;
INSERT INTO orders (id, customer_id, amount, note)
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20000)
SELECT n, n % 2000, n % 500, CONCAT('order ', n) FROM seq;
ANALYZE TABLE orders;

CREATE FUNCTION innodb_table_id(tbl VARCHAR(64)) RETURNS BIGINT READS SQL DATA
  RETURN (SELECT TABLE_ID FROM information_schema.INNODB_TABLES WHERE NAME = CONCAT(DATABASE(), '/', tbl));
CREATE FUNCTION innodb_space(tbl VARCHAR(64)) RETURNS BIGINT READS SQL DATA
  RETURN (SELECT SPACE FROM information_schema.INNODB_TABLES WHERE NAME = CONCAT(DATABASE(), '/', tbl));

-- 1. No ALGORITHM clause: MySQL picks COPY without a word.
SET @orders_id = innodb_table_id('orders');
SET @orders_space = innodb_space('orders');
-- MISTAKE: no ALGORITHM, so this type change silently runs as COPY: a new
-- table and tablespace, every row and index rewritten, writes blocked.
ALTER TABLE orders MODIFY amount BIGINT NOT NULL;
CALL assert_true(innodb_table_id('orders') <> @orders_id AND innodb_space('orders') <> @orders_space,
  'type change copied the table into a new tablespace');

-- MISTAKE: looks like a harmless widening, but 64 utf8mb4 characters cross
-- 255 bytes, so this is a copy too.
SET @orders_id = innodb_table_id('orders');
ALTER TABLE orders MODIFY note VARCHAR(64);
CALL assert_true(innodb_table_id('orders') <> @orders_id, 'VARCHAR(50) to VARCHAR(64) copied the table');

-- 2. No lock_wait_timeout: the ALTER waits behind a long transaction, and
-- every query that arrives after it waits behind the ALTER.
DELIMITER $$
CREATE PROCEDURE wait_for_other_lock(IN tbl VARCHAR(64), IN wanted_status VARCHAR(16))
BEGIN
  DECLARE tries INT DEFAULT 0;
  WHILE tries < 100 AND NOT EXISTS (
    SELECT 1 FROM performance_schema.metadata_locks
    WHERE OBJECT_SCHEMA = DATABASE() AND OBJECT_NAME = tbl
      AND LOCK_STATUS = wanted_status AND OWNER_THREAD_ID <> PS_CURRENT_THREAD_ID()) DO
    DO SLEEP(0.05);
    SET tries = tries + 1;
  END WHILE;
END$$
DELIMITER ;

SET GLOBAL event_scheduler = ON;
DELIMITER $$
CREATE EVENT hold ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  START TRANSACTION;
  SELECT COUNT(*) INTO @x FROM orders;
  DO SLEEP(4);
  COMMIT;
END$$
DELIMITER ;
CALL wait_for_other_lock('orders', 'GRANTED');

-- MISTAKE: the migration session keeps lock_wait_timeout at its default of
-- 31536000 seconds (one year), so it queues for the exclusive metadata lock
-- for as long as the transaction stays open.
CREATE EVENT migration ON SCHEDULE AT CURRENT_TIMESTAMP DO
  ALTER TABLE orders ADD COLUMN status TINYINT NOT NULL DEFAULT 0, ALGORITHM=INSTANT;
CALL wait_for_other_lock('orders', 'PENDING');
CALL assert_true(EXISTS (SELECT 1 FROM performance_schema.metadata_locks
  WHERE OBJECT_SCHEMA = DATABASE() AND OBJECT_NAME = 'orders' AND LOCK_STATUS = 'PENDING'),
  'the ALTER is queued for its exclusive metadata lock');

-- An application read now waits too (bounded at 1s here only so the test
-- can observe it; in production it waits as long as the ALTER does).
SET SESSION lock_wait_timeout = 1;
CALL assert_error('SELECT COUNT(*) FROM orders WHERE id = 1',
  'HY000', 'a plain point read is blocked behind the waiting ALTER (1205)');
SET SESSION lock_wait_timeout = DEFAULT;

-- Let the long transaction commit; the ALTER then runs and the queue drains.
DELIMITER $$
CREATE PROCEDURE wait_for_column(IN tbl VARCHAR(64), IN col VARCHAR(64))
BEGIN
  DECLARE tries INT DEFAULT 0;
  WHILE tries < 200 AND NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = tbl AND COLUMN_NAME = col) DO
    DO SLEEP(0.05);
    SET tries = tries + 1;
  END WHILE;
END$$
DELIMITER ;
CALL wait_for_column('orders', 'status');
CALL assert_true(EXISTS (SELECT 1 FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'orders' AND COLUMN_NAME = 'status'),
  'the ALTER only ran after the long transaction committed');

-- 3. Dropping an index straight away.
-- MISTAKE: DROP INDEX with no INVISIBLE step first. If a query still needed
-- it, it is now a full scan and the only way back is a full index build.
ALTER TABLE orders DROP INDEX idx_orders_customer;
EXPLAIN FORMAT=JSON INTO @plan SELECT id FROM orders WHERE customer_id = 42;
CALL assert_true(plan_has(@plan, 'ALL') OR plan_has(@plan, 'table'),
  'the customer lookup is now a full scan of the table');
