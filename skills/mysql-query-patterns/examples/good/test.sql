-- Good: one statement per page, keyset pagination written so the range
-- optimizer can use it, multi-row writes and idempotent upserts with the
-- row alias.

-- Same JSON plan shape on 8.4 (default 1) and 9.x (default 2).
SET SESSION explain_json_format_version = 1;

CREATE TABLE orders (
    id          BIGINT PRIMARY KEY,
    customer_id BIGINT NOT NULL,
    total_cents BIGINT NOT NULL,
    note        TEXT,
    created_at  DATETIME NOT NULL,
    -- The keyset index: equality column, then the sort key, then the
    -- unique tie-breaker.
    KEY orders_customer_created_id (customer_id, created_at, id)
);

CREATE TABLE order_items (
    order_id BIGINT NOT NULL,
    sku      VARCHAR(32) NOT NULL,
    qty      INT NOT NULL,
    PRIMARY KEY (order_id, sku)
);

-- 100,000 orders for 10 customers (10,000 each), three items per order.
INSERT INTO orders (id, customer_id, total_cents, created_at)
WITH RECURSIVE g (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM g WHERE n < 100000)
SELECT n, n % 10 + 1, n * 7 % 10000, TIMESTAMP '2026-01-01 00:00:00' + INTERVAL n MINUTE FROM g;

INSERT INTO order_items (order_id, sku, qty)
WITH RECURSIVE g (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM g WHERE n < 100000)
SELECT g.n, CONCAT('sku-', k.k), (g.n + k.k) % 5 + 1
FROM g, (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3) AS k;

-- The newest order of customer 3 has no items yet.
INSERT INTO orders (id, customer_id, total_cents, created_at)
VALUES (100001, 3, 500, TIMESTAMP '2026-12-31 00:00:00');

ANALYZE TABLE orders, order_items;

-- index_reads sums the session's index read counters (Handler_read_key,
-- _next, _prev, _first, _last, _rnd). The difference around a statement is
-- how many index entries it read, minus the cost of reading the counters.
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

-- 1. A page of orders with their items in one statement. The page's WHERE,
-- ORDER BY and LIMIT sit in a derived table, so the correlated subquery runs
-- once per row of the page. JSON_ARRAYAGG returns NULL for no rows, so
-- COALESCE keeps orders without items.
CREATE TABLE first_page AS
SELECT o.id, o.total_cents, o.created_at,
       COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('sku', i.sku, 'qty', i.qty))
                 FROM order_items AS i WHERE i.order_id = o.id), JSON_ARRAY()) AS items
FROM (
    SELECT id, total_cents, created_at FROM orders
    WHERE customer_id = 3
    ORDER BY created_at DESC, id DESC
    LIMIT 20
) AS o
ORDER BY o.created_at DESC, o.id DESC;

CALL assert_true((SELECT COUNT(*) FROM first_page) = 20, 'the page has 20 orders');
CALL assert_true((SELECT JSON_LENGTH(items) FROM first_page WHERE id = 100001) = 0, 'an order without items keeps an empty array');
CALL assert_true((SELECT JSON_CONTAINS(items, '{"sku": "sku-2", "qty": 5}') AND JSON_LENGTH(items) = 3 FROM first_page WHERE id = 99992), 'each order carries its own items');
CALL assert_true((SELECT COUNT(*) FROM first_page WHERE JSON_LENGTH(items) = 3) = 19, 'the other 19 orders have three items each');

-- The same statement, measured: 20 order entries, 20 lookups and 57 item
-- rows, about 100 index reads for a page of 20 orders out of 100,001.
SET @r0 = index_reads();
SELECT o.id, o.total_cents, o.created_at,
       COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('sku', i.sku, 'qty', i.qty))
                 FROM order_items AS i WHERE i.order_id = o.id), JSON_ARRAY()) AS items
FROM (
    SELECT id, total_cents, created_at FROM orders
    WHERE customer_id = 3
    ORDER BY created_at DESC, id DESC
    LIMIT 20
) AS o
ORDER BY o.created_at DESC, o.id DESC;
SET @page_reads = index_reads() - @r0 - @overhead;
CALL assert_true(@page_reads <= 120, CONCAT('one statement reads only the page and its items: ', @page_reads));

-- 2. Keyset pagination. MySQL range-scans the expanded comparison, not the
-- row constructor (see the bad example), so write it out.
-- The cursor: the last row of the page the client already has, 9,980 rows deep.
SELECT created_at, id INTO @after_created, @after_id FROM orders
WHERE customer_id = 3 ORDER BY created_at DESC, id DESC LIMIT 9979, 1;

EXPLAIN FORMAT=JSON INTO @plan
SELECT id, created_at FROM orders
WHERE customer_id = 3
AND (created_at < @after_created OR (created_at = @after_created AND id < @after_id))
ORDER BY created_at DESC, id DESC
LIMIT 20;
CALL assert_true(JSON_UNQUOTE(JSON_EXTRACT(@plan, '$.query_block.ordering_operation.table.access_type')) = 'range', 'the keyset page is a range scan');
CALL assert_true(plan_has(@plan, 'orders_customer_created_id'), 'on the keyset index');
CALL assert_true(JSON_EXTRACT(@plan, '$.query_block.ordering_operation.using_filesort') = false, 'with no filesort');
CALL assert_true(JSON_EXTRACT(@plan, '$.query_block.ordering_operation.table.using_index') = true, 'and covered by the index, because the columns are named');

-- The deepest page reads about 20 index entries, the same as the first.
SET @r0 = index_reads();
SELECT id, created_at FROM orders
WHERE customer_id = 3
AND (created_at < @after_created OR (created_at = @after_created AND id < @after_id))
ORDER BY created_at DESC, id DESC
LIMIT 20;
SET @keyset_reads = index_reads() - @r0 - @overhead;
CALL assert_true(@keyset_reads <= 25, CONCAT('a deep keyset page reads only the rows it returns: ', @keyset_reads));

-- A row inserted between two requests does not shift the next page.
CREATE TABLE page1 AS
SELECT id, created_at FROM orders WHERE customer_id = 3
ORDER BY created_at DESC, id DESC LIMIT 20;
SELECT created_at, id INTO @after_created, @after_id FROM page1 ORDER BY created_at, id LIMIT 1;
INSERT INTO orders (id, customer_id, total_cents, created_at)
VALUES (100002, 3, 100, TIMESTAMP '2027-01-01 00:00:00');
CREATE TABLE page2 AS
SELECT id, created_at FROM orders
WHERE customer_id = 3
AND (created_at < @after_created OR (created_at = @after_created AND id < @after_id))
ORDER BY created_at DESC, id DESC
LIMIT 20;
CALL assert_true((SELECT COUNT(*) FROM page2) = 20, 'the second page is full');
CALL assert_true(NOT EXISTS (SELECT 1 FROM page2 JOIN page1 USING (id)), 'no row appears on both pages');
CALL assert_true((SELECT MAX(id) FROM page2) = @after_id - 10, 'the second page starts right after the first');

-- 3. Batch writes: one multi-row INSERT, not one INSERT per row. Keep each
-- statement under max_allowed_packet (64 MiB by default).
SET @c0 = (SELECT variable_value FROM performance_schema.session_status WHERE variable_name = 'Handler_commit');
INSERT INTO order_items (order_id, sku, qty) VALUES
    (100001, 'sku-a', 2),
    (100001, 'sku-b', 1),
    (100001, 'sku-c', 5);
SET @batch_rows = ROW_COUNT();
CALL assert_true(@batch_rows = 3, 'one statement inserts three rows');
-- 1,000 generated rows, still one statement and one commit.
INSERT INTO order_items (order_id, sku, qty)
WITH RECURSIVE g (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM g WHERE n < 1000)
SELECT 100002, CONCAT('extra-', n), 1 FROM g;
SET @batch_rows = ROW_COUNT();
SET @commits = (SELECT variable_value FROM performance_schema.session_status WHERE variable_name = 'Handler_commit') - @c0;
CALL assert_true(@batch_rows = 1000, 'one statement inserts 1,000 rows');
CALL assert_true(@commits <= 10, CONCAT('two batch statements cost a handful of commits, not one per row: ', @commits));

-- 4. Upsert with the row alias: a rerun of the same batch changes nothing,
-- and affected rows report 1 per insert, 2 per update, 0 per unchanged row.
CREATE TABLE stock (
    sku       VARCHAR(32) PRIMARY KEY,
    available INT NOT NULL
);

INSERT INTO stock (sku, available) VALUES ('sku-1', 10), ('sku-2', 20), ('sku-3', 30) AS new
ON DUPLICATE KEY UPDATE available = new.available;
SET @run1 = ROW_COUNT();
SET @run1_warnings = @@warning_count;
INSERT INTO stock (sku, available) VALUES ('sku-1', 10), ('sku-2', 20), ('sku-3', 30) AS new
ON DUPLICATE KEY UPDATE available = new.available;
SET @run2 = ROW_COUNT();
INSERT INTO stock (sku, available) VALUES ('sku-1', 10), ('sku-2', 20), ('sku-3', 31) AS new
ON DUPLICATE KEY UPDATE available = new.available;
SET @run3 = ROW_COUNT();

CALL assert_true(@run1 = 3, 'the first run inserts three rows');
CALL assert_true(@run1_warnings = 0, 'the row alias raises no deprecation warning');
CALL assert_true(@run2 = 0, 'the identical rerun changes nothing');
CALL assert_true(@run3 = 2, 'a rerun with one changed value updates one row (2 affected rows)');
CALL assert_true((SELECT COUNT(*) FROM stock) = 3, 'no duplicate rows');
CALL assert_true((SELECT available FROM stock WHERE sku = 'sku-3') = 31, 'the changed value is stored');

-- 5. Plain EXPLAIN plans the statement without running it: the deep OFFSET
-- query that reads 10,000 rows (bad example) reads none here.
SET @r0 = index_reads();
EXPLAIN FORMAT=JSON INTO @plan
SELECT id, created_at FROM orders WHERE customer_id = 3
ORDER BY created_at DESC, id DESC LIMIT 20 OFFSET 9980;
SET @explain_reads = index_reads() - @r0 - @overhead;
CALL assert_true(@explain_reads <= 5, CONCAT('EXPLAIN without ANALYZE does not execute: ', @explain_reads));
