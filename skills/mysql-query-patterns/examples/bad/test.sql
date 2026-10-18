-- Bad: OFFSET pagination, a row-constructor keyset, a query per row,
-- row-by-row inserts, VALUES() upserts, upserts on a table with two unique
-- keys, SELECT *, EXPLAIN ANALYZE and ORDER BY RAND(). The assertions
-- describe the bad outcome, so this file fails if a mistake stops costing
-- what the skill says it costs.

SET SESSION explain_json_format_version = 1;

CREATE TABLE orders (
    id          BIGINT PRIMARY KEY,
    customer_id BIGINT NOT NULL,
    total_cents BIGINT NOT NULL,
    note        TEXT,
    created_at  DATETIME NOT NULL,
    KEY orders_customer_created_id (customer_id, created_at, id)
);

CREATE TABLE order_items (
    order_id BIGINT NOT NULL,
    sku      VARCHAR(32) NOT NULL,
    qty      INT NOT NULL,
    PRIMARY KEY (order_id, sku)
);

-- 100,000 orders for 10 customers: 10,000 orders per customer.
INSERT INTO orders (id, customer_id, total_cents, created_at)
WITH RECURSIVE g (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM g WHERE n < 100000)
SELECT n, n % 10 + 1, n * 7 % 10000, TIMESTAMP '2026-01-01 00:00:00' + INTERVAL n MINUTE FROM g;

INSERT INTO order_items (order_id, sku, qty)
WITH RECURSIVE g (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM g WHERE n < 100000)
SELECT g.n, CONCAT('sku-', k.k), (g.n + k.k) % 5 + 1
FROM g, (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3) AS k;

ANALYZE TABLE orders, order_items;

-- index_reads sums the session's index read counters; the difference around
-- a statement is how many index entries it read.
DELIMITER $$
CREATE FUNCTION index_reads() RETURNS BIGINT READS SQL DATA
BEGIN
  RETURN (SELECT SUM(variable_value) FROM performance_schema.session_status
          WHERE variable_name IN ('Handler_read_key', 'Handler_read_next', 'Handler_read_prev',
                                  'Handler_read_first', 'Handler_read_last', 'Handler_read_rnd'));
END$$
DELIMITER ;
SET @r0 = index_reads();
SET @r1 = index_reads();
SET @overhead = @r1 - @r0;

-- 1. Deep OFFSET.
SET @r0 = index_reads();
-- MISTAKE: OFFSET reads and throws away every earlier row. The last page of
-- this customer reads 10,000 index entries to return 20; cost grows with depth.
SELECT id, created_at FROM orders WHERE customer_id = 3
ORDER BY created_at DESC, id DESC LIMIT 20 OFFSET 9980;
SET @offset_reads = index_reads() - @r0 - @overhead;
CALL assert_true(@offset_reads >= 10000, CONCAT('the deep OFFSET page reads 10,000 rows to return 20: ', @offset_reads));

-- 2. OFFSET pages shift when a row is inserted between two requests.
CREATE TABLE page1 AS
SELECT id FROM orders WHERE customer_id = 3 ORDER BY created_at DESC, id DESC LIMIT 20 OFFSET 0;
INSERT INTO orders (id, customer_id, total_cents, created_at)
VALUES (100002, 3, 100, TIMESTAMP '2027-01-01 00:00:00');
-- MISTAKE: the new row pushes every row down by one, so the next page
-- repeats the last row the client already has (and a delete would skip one).
CREATE TABLE page2 AS
SELECT id FROM orders WHERE customer_id = 3 ORDER BY created_at DESC, id DESC LIMIT 20 OFFSET 20;
CALL assert_true((SELECT COUNT(*) FROM page2 JOIN page1 USING (id)) = 1, 'one row appears on both OFFSET pages');

-- 3. Keyset written as a row constructor.
SELECT created_at, id INTO @after_created, @after_id FROM orders
WHERE customer_id = 3 ORDER BY created_at DESC, id DESC LIMIT 9980, 1;
EXPLAIN FORMAT=JSON INTO @plan
SELECT id, created_at FROM orders
WHERE customer_id = 3 AND (created_at, id) < (@after_created, @after_id)
ORDER BY created_at DESC, id DESC LIMIT 20;
CALL assert_true(JSON_UNQUOTE(JSON_EXTRACT(@plan, '$.query_block.ordering_operation.table.access_type')) = 'ref', 'the row constructor is not a range: the index is read from the start of customer 3');
SET @r0 = index_reads();
-- MISTAKE: MySQL range-optimizes row constructors only inside IN (). This
-- page is filtered after reading the index from the newest row, so the deep
-- page reads as many rows as OFFSET does.
SELECT id, created_at FROM orders
WHERE customer_id = 3 AND (created_at, id) < (@after_created, @after_id)
ORDER BY created_at DESC, id DESC LIMIT 20;
SET @row_keyset_reads = index_reads() - @r0 - @overhead;
CALL assert_true(@row_keyset_reads >= 10000, CONCAT('the row-constructor keyset reads 10,000 rows: ', @row_keyset_reads));

-- 4. N+1: one query per order of the page, run here as a stored procedure
-- so performance_schema can count it.
DELIMITER $$
CREATE PROCEDURE page_items_n_plus_1()
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE oid BIGINT;
  DECLARE page CURSOR FOR
    SELECT id FROM orders WHERE customer_id = 3 ORDER BY created_at DESC, id DESC LIMIT 20;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
  OPEN page;
  fetch_loop: LOOP
    FETCH page INTO oid;
    IF done THEN LEAVE fetch_loop; END IF;
    -- MISTAKE: one statement per order. From an application this is one
    -- round trip each: 20 orders cost 21 statements instead of one.
    SELECT JSON_ARRAYAGG(JSON_OBJECT('sku', sku, 'qty', qty)) INTO @items FROM order_items WHERE order_id = oid;
  END LOOP;
  CLOSE page;
END$$
DELIMITER ;
CALL page_items_n_plus_1();
CALL assert_true((SELECT count_statements FROM performance_schema.events_statements_summary_by_program
                  WHERE object_name = 'page_items_n_plus_1') >= 20, 'the page ran one item query per order');

-- 5. Row-by-row inserts in autocommit.
DELIMITER $$
CREATE PROCEDURE insert_row_by_row()
BEGIN
  DECLARE n INT DEFAULT 0;
  WHILE n < 1000 DO
    -- MISTAKE: one INSERT per row. 1,000 rows cost 1,000 statements and, in
    -- autocommit, 1,000 commits (from a client, also 1,000 round trips)
    -- where one multi-row INSERT does the same work.
    INSERT INTO order_items (order_id, sku, qty) VALUES (100002, CONCAT('extra-', n), 1);
    SET n = n + 1;
  END WHILE;
END$$
DELIMITER ;
SET @c0 = (SELECT variable_value FROM performance_schema.session_status WHERE variable_name = 'Handler_commit');
CALL insert_row_by_row();
SET @commits = (SELECT variable_value FROM performance_schema.session_status WHERE variable_name = 'Handler_commit') - @c0;
CALL assert_true((SELECT count_statements FROM performance_schema.events_statements_summary_by_program
                  WHERE object_name = 'insert_row_by_row') >= 1000, '1,000 rows took 1,000 INSERT statements');
CALL assert_true(@commits >= 1000, CONCAT('and at least one commit per row: ', @commits));

-- 6. VALUES() in ON DUPLICATE KEY UPDATE.
CREATE TABLE stock (
    sku       VARCHAR(32) PRIMARY KEY,
    available INT NOT NULL
);
-- MISTAKE: VALUES() to read the new row is deprecated and subject to removal;
-- every execution raises warning 1287. Use INSERT ... AS new and new.col.
INSERT INTO stock (sku, available) VALUES ('sku-1', 10), ('sku-2', 20)
ON DUPLICATE KEY UPDATE available = VALUES(available);
GET DIAGNOSTICS CONDITION 1 @warn_code = MYSQL_ERRNO;
CALL assert_true(@warn_code = 1287, 'VALUES() raises the deprecation warning 1287');

-- 7. Upsert on a table with two unique keys.
CREATE TABLE users (
    id    BIGINT PRIMARY KEY,
    email VARCHAR(255) NOT NULL UNIQUE,
    name  VARCHAR(100) NOT NULL
);
INSERT INTO users (id, email, name) VALUES (1, 'ana@example.com', 'Ana'), (2, 'bia@example.com', 'Bia');
-- MISTAKE: the new row collides with user 1 on id and with user 2 on email.
-- MySQL updates only one of them, reports success, and the row the caller
-- asked for (id 1 with bia's email) does not exist afterwards.
INSERT INTO users (id, email, name) VALUES (1, 'bia@example.com', 'Carla') AS new
ON DUPLICATE KEY UPDATE name = new.name;
SET @multi_unique_rows = ROW_COUNT();
CALL assert_true(@multi_unique_rows = 2, 'the upsert reports one updated row');
CALL assert_true((SELECT COUNT(*) FROM users WHERE name = 'Carla') = 1, 'only one of the two conflicting rows changed');
CALL assert_true(NOT EXISTS (SELECT 1 FROM users WHERE id = 1 AND email = 'bia@example.com'), 'the requested row does not exist');

-- 8. SELECT * on a list query.
-- MISTAKE: SELECT * needs total_cents and the TEXT note, which are not in the
-- index, so every row of the page is also read from the clustered index.
EXPLAIN FORMAT=JSON INTO @plan
SELECT * FROM orders WHERE customer_id = 3 ORDER BY created_at DESC, id DESC LIMIT 20;
CALL assert_true(JSON_EXTRACT(@plan, '$.query_block.ordering_operation.table.using_index') IS NULL, 'SELECT * is not covered by the index');

-- 9. EXPLAIN ANALYZE runs the statement.
SET @r0 = index_reads();
-- MISTAKE: EXPLAIN ANALYZE executes the query to measure it, so on a
-- production primary it costs as much as the slow query you are diagnosing.
EXPLAIN ANALYZE FORMAT=TREE
SELECT id, created_at FROM orders WHERE customer_id = 3
ORDER BY created_at DESC, id DESC LIMIT 20 OFFSET 9980;
SET @analyze_reads = index_reads() - @r0 - @overhead;
CALL assert_true(@analyze_reads >= 10000, CONCAT('EXPLAIN ANALYZE read the 10,000 rows: ', @analyze_reads));

-- 10. ORDER BY RAND() for one random row.
-- MISTAKE: RAND() is evaluated for every row, so the server scans all
-- 100,000 orders and sorts them to return one.
EXPLAIN FORMAT=JSON INTO @plan
SELECT id, total_cents FROM orders ORDER BY RAND() LIMIT 1;
CALL assert_true(plan_has(@plan, 'ALL'), 'ORDER BY RAND() scans the whole table');
CALL assert_true(JSON_EXTRACT(@plan, '$.query_block.ordering_operation.table.rows_examined_per_scan') >= 90000, 'all 100,000 rows');
CALL assert_true(JSON_EXTRACT(@plan, '$.query_block.ordering_operation.using_filesort') = true, 'and sorts it');
