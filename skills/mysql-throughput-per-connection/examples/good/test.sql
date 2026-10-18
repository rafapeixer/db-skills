-- Good: each request holds its connection for as little time as possible.
-- A page and its items in one statement, writes grouped so one commit (one
-- redo log and binary log flush) covers many rows, a queue claimed with
-- SKIP LOCKED under READ COMMITTED and worked on after COMMIT, and a hot
-- counter split into 16 shards picked in the client. Other sessions are
-- events: the event scheduler runs each body in its own connection. Events
-- wait on user locks (GET_LOCK) that this session holds, so they move only
-- when this session lets them, however slow the machine is.
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

-- Work queue. MySQL has no partial index, so (status, id) serves the claim.
CREATE TABLE jobs (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  claimed_at DATETIME(6) NULL,
  KEY jobs_status_id (status, id)
);
INSERT INTO jobs (status)
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000)
SELECT 'pending' FROM seq;

-- Hot counter: 16 shards of 1,000 units each.
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
ANALYZE TABLE orders, order_items, jobs, stock_shards;

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

-- n sales, each a single autocommit UPDATE of one shard. The shard is picked
-- before the statement, as the application would bind it as a parameter.
CREATE PROCEDURE sell(IN n INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  DECLARE shard_pick INT;
  SET @sold = 0;
  WHILE i < n DO
    SET shard_pick = FLOOR(RAND() * 16);
    UPDATE stock_shards SET qty = qty - 1 WHERE sku = 'SKU-1' AND shard = shard_pick;
    SET @sold = @sold + ROW_COUNT();
    SET i = i + 1;
  END WHILE;
END$$

-- The same sale in one statement, the random shard computed once in a
-- derived table that NO_MERGE keeps from being merged into the UPDATE.
CREATE PROCEDURE sell_in_one_statement(IN n INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  DECLARE changed INT;
  SET @exact = 0;
  WHILE i < n DO
    UPDATE /*+ NO_MERGE(dt) */ stock_shards AS s, (SELECT FLOOR(RAND() * 16) AS r) AS dt
    SET s.qty = s.qty - 1 WHERE s.sku = 'SKU-1' AND s.shard = dt.r;
    SET changed = ROW_COUNT();
    IF changed = 1 THEN SET @exact = @exact + 1; END IF;
    SET i = i + 1;
  END WHILE;
END$$

DELIMITER ;

-- 1. The page of 10 orders and their items: one statement, one round trip.
EXPLAIN FORMAT=JSON INTO @plan
SELECT o.id, o.total, o.created_at, i.items
FROM (SELECT id, total, created_at FROM orders WHERE customer_id = 7
      ORDER BY created_at DESC, id DESC LIMIT 10) AS o
LEFT JOIN LATERAL (SELECT JSON_ARRAYAGG(JSON_OBJECT('sku', sku, 'qty', qty)) AS items
                   FROM order_items WHERE order_id = o.id) AS i ON TRUE
ORDER BY o.created_at DESC, o.id DESC;
CALL assert_true(plan_has(@plan, 'orders_customer_created'), 'the page reads the (customer_id, created_at, id) index');
CALL assert_true(JSON_CONTAINS(JSON_EXTRACT(@plan, '$**.key'), '"PRIMARY"'), 'each order finds its items through the primary key');

SELECT o.id, o.total, o.created_at, i.items
FROM (SELECT id, total, created_at FROM orders WHERE customer_id = 7
      ORDER BY created_at DESC, id DESC LIMIT 10) AS o
LEFT JOIN LATERAL (SELECT JSON_ARRAYAGG(JSON_OBJECT('sku', sku, 'qty', qty)) AS items
                   FROM order_items WHERE order_id = o.id) AS i ON TRUE
ORDER BY o.created_at DESC, o.id DESC;

-- performance_schema groups statements by digest (the text with literals
-- replaced by ?). The application sent the page once and no item query.
CALL assert_true((SELECT SUM(COUNT_STAR) FROM performance_schema.events_statements_summary_by_digest
                  WHERE SCHEMA_NAME = DATABASE() AND DIGEST_TEXT LIKE 'SELECT `o` . `id`%LATERAL%') = 1,
                 'the page with its items is 1 statement');
CALL assert_true((SELECT COUNT(*) FROM performance_schema.events_statements_summary_by_digest
                  WHERE SCHEMA_NAME = DATABASE() AND DIGEST_TEXT LIKE '%FROM `order_items` WHERE `order_id` = ?%') = 0,
                 'no query per order');

SELECT COUNT(*), SUM(JSON_LENGTH(items)) INTO @orders, @items FROM (
  SELECT o.id, i.items
  FROM (SELECT id FROM orders WHERE customer_id = 7 ORDER BY created_at DESC, id DESC LIMIT 10) AS o
  LEFT JOIN LATERAL (SELECT JSON_ARRAYAGG(JSON_OBJECT('sku', sku, 'qty', qty)) AS items
                     FROM order_items WHERE order_id = o.id) AS i ON TRUE
) AS page;
CALL assert_true(@orders = 10 AND @items = 30, 'the page has 10 orders with 3 items each');

-- 2. Writes: the cost is the commit, so let one commit cover many rows.
-- The durable defaults stay: a flush of the redo log and the binary log per commit.
CALL assert_true(@@GLOBAL.innodb_flush_log_at_trx_commit = 1 AND @@GLOBAL.sync_binlog = 1 AND @@GLOBAL.log_bin = 1,
                 'durable defaults: redo log and binary log flushed at every commit');
SELECT VARIABLE_VALUE INTO @fsyncs FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_os_log_fsyncs';

START TRANSACTION;
INSERT INTO orders (customer_id, total, created_at) VALUES (7, 30.00, NOW(6));
INSERT INTO order_items (order_id, sku, qty) VALUES
  (LAST_INSERT_ID(), 'A1', 1), (LAST_INSERT_ID(), 'B1', 2), (LAST_INSERT_ID(), 'C1', 3);
COMMIT;

-- 200 sale lines, 200 INSERT statements, one transaction and one commit.
START TRANSACTION;
CALL record_sales(200);
COMMIT;

SELECT VARIABLE_VALUE - @fsyncs INTO @fsyncs FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_os_log_fsyncs';
CALL assert_true((SELECT COUNT(*) FROM sale_lines) = 200, '200 sale lines written');
CALL assert_true(@fsyncs <= 20, 'two commits cost a handful of redo log fsyncs, not one per row');

-- 3. Queue: claim with SKIP LOCKED under READ COMMITTED, commit, then work.
-- Worker 2 waits on the 'start' lock until worker 1 (this session) holds its
-- claim, and does its work only when this session releases 'work'.
SET @start = CONCAT(DATABASE(), '.start'), @work = CONCAT(DATABASE(), '.work');
CALL assert_true(GET_LOCK(@start, 0) = 1 AND GET_LOCK(@work, 0) = 1, 'this session holds both gates');
DELIMITER $$
CREATE EVENT worker2 ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  IF GET_LOCK(CONCAT(DATABASE(), '.start'), 120) = 1 THEN
    SET SESSION transaction_isolation = 'READ-COMMITTED';
    START TRANSACTION;
    SELECT id INTO @id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED;
    UPDATE jobs SET status = 'running', claimed_at = NOW(6) WHERE id = @id;
    COMMIT;
    INSERT INTO steps VALUES ('worker 2 claimed', CONNECTION_ID(), @id);
    -- The work runs after COMMIT: no transaction, no row lock.
    IF GET_LOCK(CONCAT(DATABASE(), '.work'), 120) = 1 THEN
      UPDATE jobs SET status = 'done' WHERE id = @id;
      INSERT INTO steps VALUES ('worker 2 done', CONNECTION_ID(), @id);
    END IF;
  END IF;
END$$
DELIMITER ;

SET SESSION transaction_isolation = 'READ-COMMITTED';
START TRANSACTION;
SELECT id INTO @job FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED;
UPDATE jobs SET status = 'running', claimed_at = NOW(6) WHERE id = @job;
-- Worker 1's claim is still open when worker 2 claims.
DO RELEASE_LOCK(@start);
CALL wait_for_step('worker 2 claimed');
SELECT val, conn INTO @job2, @worker2 FROM steps WHERE name = 'worker 2 claimed';
CALL assert_true(@job = 1 AND @job2 = 2, 'worker 2 got job 2 at once while worker 1 held job 1');
CALL assert_true((SELECT COUNT(*) FROM information_schema.innodb_trx WHERE trx_mysql_thread_id = CONNECTION_ID()) = 1,
                 'worker 2 claimed and committed while worker 1 transaction was still open');
COMMIT;

-- While worker 2 works, its connection has no transaction and no row lock.
CALL assert_true((SELECT COUNT(*) FROM information_schema.innodb_trx WHERE trx_mysql_thread_id = @worker2) = 0,
                 'worker 2 holds no transaction while it works');
CALL assert_true((SELECT COUNT(*) FROM performance_schema.processlist WHERE id = @worker2) = 1,
                 'worker 2 is still connected, doing its work');
DO RELEASE_LOCK(@work);
CALL wait_for_step('worker 2 done');
CALL assert_true((SELECT GROUP_CONCAT(id ORDER BY id) FROM jobs WHERE status <> 'pending') = '1,2', 'each job claimed once');

-- 4. Hot counter: a sale holding shard 0 blocks neither a sale on shard 1
-- nor a read of the total.
SET @hold = CONCAT(DATABASE(), '.hold');
CALL assert_true(GET_LOCK(@hold, 0) = 1, 'this session holds the hold gate');
DELIMITER $$
CREATE EVENT sale_on_shard_0 ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  START TRANSACTION;
  UPDATE stock_shards SET qty = qty - 1 WHERE sku = 'SKU-1' AND shard = 0;
  DO GET_LOCK(CONCAT(DATABASE(), '.hold'), 120);
  COMMIT;
  INSERT INTO steps VALUES ('shard 0 sold', CONNECTION_ID(), NULL);
END$$
DELIMITER ;

CALL wait_for_lock('stock_shards');
-- 1 s only so the test fails fast if the sale ever had to wait.
SET SESSION innodb_lock_wait_timeout = 1;
UPDATE stock_shards SET qty = qty - 1 WHERE sku = 'SKU-1' AND shard = 1;
CALL assert_true(ROW_COUNT() = 1, 'a sale on shard 1 did not wait for shard 0');
SELECT SUM(qty) INTO @total FROM stock_shards WHERE sku = 'SKU-1';
CALL assert_true(@total = 15999, 'the total reads without waiting and sees committed sales');
DO RELEASE_LOCK(@hold);
CALL wait_for_step('shard 0 sold');
SET SESSION innodb_lock_wait_timeout = 50;

-- 1,000 sales from two concurrent sessions: the shards add up exactly.
DELIMITER $$
CREATE EVENT concurrent_sales ON SCHEDULE AT CURRENT_TIMESTAMP DO
BEGIN
  CALL sell(500);
  INSERT INTO steps VALUES ('event sold 500', CONNECTION_ID(), @sold);
END$$
DELIMITER ;
CALL sell(500);
CALL wait_for_step('event sold 500');
CALL assert_true(@sold = 500 AND (SELECT val FROM steps WHERE name = 'event sold 500') = 500,
                 'every sale changed exactly one shard');
SELECT SUM(qty) INTO @total FROM stock_shards WHERE sku = 'SKU-1';
CALL assert_true(@total = 14998, 'the shards add up to 16,000 minus 1,002 sales');

-- Picking the shard on the server: compute it once in a derived table.
CALL sell_in_one_statement(200);
CALL assert_true(@exact = 200, 'each one-statement sale changed exactly one shard');
CALL assert_true((SELECT SUM(qty) FROM stock_shards WHERE sku = 'SKU-1') = 14798, 'the shards add up after 200 more sales');

CALL cleanup_sessions();
DROP EVENT IF EXISTS worker2;
DROP EVENT IF EXISTS sale_on_shard_0;
DROP EVENT IF EXISTS concurrent_sales;
