-- mysql-indexing, good example: each index matches the query it serves.
-- 200k orders over 10k customers, 200k tickets over 50 queues and 40 agents.

-- The assertions read the classic JSON plan (access_type, key, using_index,
-- using_filesort). MySQL 9.x defaults to format version 2, so pin version 1.
SET SESSION explain_json_format_version = 1;

CREATE TABLE orders (
  id BIGINT PRIMARY KEY,
  customer_id INT NOT NULL,
  status VARCHAR(16) NOT NULL,
  ref_code VARCHAR(20) NOT NULL,
  created_at DATETIME NOT NULL,
  total DECIMAL(10, 2) NOT NULL,
  payload JSON NOT NULL
);

CREATE TABLE tickets (
  id BIGINT PRIMARY KEY,
  queue_id INT NOT NULL,
  agent_id INT NOT NULL,
  priority TINYINT NOT NULL,
  created_at DATETIME NOT NULL
);

-- About 20 orders per customer; 1% pending; ref_code is a numeric-looking string.
INSERT INTO orders
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 200000)
SELECT n, 1 + (n * 7919) % 10000,
       CASE WHEN n % 100 = 0 THEN 'pending' WHEN n % 10 = 0 THEN 'cancelled' ELSE 'shipped' END,
       CAST(n AS CHAR),
       TIMESTAMP '2026-01-01 00:00:00' + INTERVAL n MINUTE,
       (n % 500) + 0.99,
       JSON_OBJECT('tracking', CONCAT('TRK', n), 'channel', IF(n % 2 = 0, 'web', 'app'))
FROM seq;

-- 4000 tickets per queue, 5000 per agent, 100 per (queue, agent) pair.
INSERT INTO tickets
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 200000)
SELECT n, n % 50, (n DIV 50) % 40, (n DIV 7) % 5,
       TIMESTAMP '2026-01-01 00:00:00' + INTERVAL n MINUTE
FROM seq;

-- Equality column first, then the range/sort column. The primary key (id) is
-- already in every secondary index, so SELECT id, created_at is covered.
CREATE INDEX orders_customer_created_idx ON orders (customer_id, created_at);

-- Plain column indexes, queried with matching types and no function around the column.
CREATE INDEX orders_ref_code_idx ON orders (ref_code);
CREATE INDEX orders_created_idx ON orders (created_at);

-- Functional index (8.0.13+): the query repeats this exact expression.
CREATE INDEX orders_tracking_idx ON orders ((CAST(payload->>'$.tracking' AS CHAR(32))));

-- One composite index for an AND of two equalities, instead of two single-column ones.
CREATE INDEX tickets_queue_agent_idx ON tickets (queue_id, agent_id);

-- Mixed sort directions (priority ASC, created_at DESC): the index stores them the same way.
CREATE INDEX tickets_queue_priority_created_idx ON tickets (queue_id, priority, created_at DESC);

-- A drop candidate: hidden from the optimizer first, still maintained, reversible instantly.
CREATE INDEX orders_status_idx ON orders (status);
ANALYZE TABLE orders, tickets;

-- 1. WHERE a = ? AND b >= ? ORDER BY b: one index range, covered, rows already in order.
EXPLAIN FORMAT=JSON INTO @p SELECT id, created_at FROM orders WHERE customer_id = 42 AND created_at >= '2026-03-01' ORDER BY created_at LIMIT 20;
CALL assert_true(plan_has(@p, 'orders_customer_created_idx'), 'composite index serves the customer query');
CALL assert_true(plan_has(@p, 'range') OR plan_has(@p, 'ref'), 'customer query seeks the index');
CALL assert_true(JSON_CONTAINS(JSON_EXTRACT(@p, '$**.using_index'), 'true'), 'covering: id comes from the secondary index');
CALL assert_true(NOT JSON_CONTAINS(COALESCE(JSON_EXTRACT(@p, '$**.using_filesort'), JSON_ARRAY()), 'true'), 'index order satisfies ORDER BY, no filesort');
CALL assert_true(JSON_EXTRACT(JSON_EXTRACT(@p, '$**.rows_examined_per_scan'), '$[0]') < 50, 'customer query examines a few dozen rows at most');

-- 2. String column compared with a string literal: index lookup.
EXPLAIN FORMAT=JSON INTO @p SELECT * FROM orders WHERE ref_code = '4242';
CALL assert_true(plan_has(@p, 'orders_ref_code_idx') AND plan_has(@p, 'ref'), 'VARCHAR = string literal uses the index');

-- 3. A day of orders written as a range on the bare column, not DATE(created_at).
EXPLAIN FORMAT=JSON INTO @p SELECT * FROM orders WHERE created_at >= '2026-03-01' AND created_at < '2026-03-02';
CALL assert_true(plan_has(@p, 'orders_created_idx') AND plan_has(@p, 'range'), 'range on the bare column uses the index');

-- 4. JSON attribute lookup through the functional index.
EXPLAIN FORMAT=JSON INTO @p SELECT * FROM orders WHERE CAST(payload->>'$.tracking' AS CHAR(32)) = 'TRK4242';
CALL assert_true(plan_has(@p, 'orders_tracking_idx') AND NOT plan_has(@p, 'ALL'), 'functional index serves the JSON lookup');

-- 5. AND of two equalities: one ref lookup on the composite, no index_merge.
EXPLAIN FORMAT=JSON INTO @p SELECT id, created_at FROM tickets WHERE queue_id = 7 AND agent_id = 3;
CALL assert_true(plan_has(@p, 'tickets_queue_agent_idx') AND plan_has(@p, 'ref'), 'composite index serves both equalities');
CALL assert_true(NOT plan_has(@p, 'index_merge'), 'no index merge');

-- 6. Mixed directions read from the descending index without a filesort.
EXPLAIN FORMAT=JSON INTO @p SELECT id, priority, created_at FROM tickets WHERE queue_id = 7 ORDER BY priority ASC, created_at DESC LIMIT 20;
CALL assert_true(plan_has(@p, 'tickets_queue_priority_created_idx'), 'descending index serves the mixed ORDER BY');
CALL assert_true(NOT JSON_CONTAINS(COALESCE(JSON_EXTRACT(@p, '$**.using_filesort'), JSON_ARRAY()), 'true'), 'mixed ORDER BY needs no filesort');

-- 7. Before dropping an index, make it invisible and watch the workload.
EXPLAIN FORMAT=JSON INTO @p SELECT id FROM orders WHERE status = 'pending';
CALL assert_true(plan_has(@p, 'orders_status_idx'), 'visible index is used');
ALTER TABLE orders ALTER INDEX orders_status_idx INVISIBLE;
EXPLAIN FORMAT=JSON INTO @p SELECT id FROM orders WHERE status = 'pending';
CALL assert_true(NOT plan_has(@p, 'orders_status_idx'), 'invisible index is ignored by the optimizer');
CALL assert_true((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema = DATABASE() AND index_name = 'orders_status_idx' AND is_visible = 'NO') = 1, 'index still exists, marked invisible');
-- One session can still test it, without changing the plan for anyone else.
EXPLAIN FORMAT=JSON INTO @p SELECT /*+ SET_VAR(optimizer_switch = 'use_invisible_indexes=on') */ id FROM orders WHERE status = 'pending';
CALL assert_true(plan_has(@p, 'orders_status_idx'), 'use_invisible_indexes=on sees it again');
-- If something regresses, ALTER INDEX ... VISIBLE brings it back with no rebuild.
ALTER TABLE orders ALTER INDEX orders_status_idx VISIBLE;

-- 8. No index duplicates or is a left prefix of another.
SELECT redundant_index_name, dominant_index_name, sql_drop_index FROM sys.schema_redundant_indexes WHERE table_schema = DATABASE();
CALL assert_true((SELECT COUNT(*) FROM sys.schema_redundant_indexes WHERE table_schema = DATABASE()) = 0, 'no redundant indexes');

-- Queries return the right rows.
CALL assert_true((SELECT COUNT(*) FROM orders WHERE ref_code = '4242') = 1, 'one order per ref_code');
CALL assert_true((SELECT COUNT(*) FROM orders WHERE created_at >= '2026-03-01' AND created_at < '2026-03-02') = 1440, 'a day has 1440 orders');
CALL assert_true((SELECT COUNT(*) FROM tickets WHERE queue_id = 7 AND agent_id = 3) = 100, '100 tickets per queue and agent');
