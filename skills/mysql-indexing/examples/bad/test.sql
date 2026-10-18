-- mysql-indexing, bad example: same tables and queries as the good example,
-- with the indexes and predicates agents usually write instead.

-- The assertions read the classic JSON plan; MySQL 9.x defaults to version 2.
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

INSERT INTO orders
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 200000)
SELECT n, 1 + (n * 7919) % 10000,
       CASE WHEN n % 100 = 0 THEN 'pending' WHEN n % 10 = 0 THEN 'cancelled' ELSE 'shipped' END,
       CAST(n AS CHAR),
       TIMESTAMP '2026-01-01 00:00:00' + INTERVAL n MINUTE,
       (n % 500) + 0.99,
       JSON_OBJECT('tracking', CONCAT('TRK', n), 'channel', IF(n % 2 = 0, 'web', 'app'))
FROM seq;

INSERT INTO tickets
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 200000)
SELECT n, n % 50, (n DIV 50) % 40, (n DIV 7) % 5,
       TIMESTAMP '2026-01-01 00:00:00' + INTERVAL n MINUTE
FROM seq;

-- MISTAKE: range column first. The seek stops at created_at, so one customer's 11 rows cost a scan of every order since March.
CREATE INDEX orders_created_customer_idx ON orders (created_at, customer_id);

-- MISTAKE: a left prefix of the index above. Every insert pays for both; sys.schema_redundant_indexes flags it.
CREATE INDEX orders_created_idx ON orders (created_at);

CREATE INDEX orders_ref_code_idx ON orders (ref_code);

-- MISTAKE: two single-column indexes for an AND of two equalities. The optimizer intersects them (index_merge) instead of one seek.
CREATE INDEX tickets_queue_idx ON tickets (queue_id);
CREATE INDEX tickets_agent_idx ON tickets (agent_id);

-- MISTAKE: all-ascending index for ORDER BY priority ASC, created_at DESC. The rows still go through a filesort.
CREATE INDEX tickets_queue_priority_created_idx ON tickets (queue_id, priority, created_at);
ANALYZE TABLE orders, tickets;

-- Wrong column order: the index is used, but the range examines about half the table.
EXPLAIN FORMAT=JSON INTO @p SELECT id, created_at FROM orders WHERE customer_id = 42 AND created_at >= '2026-03-01' ORDER BY created_at LIMIT 20;
CALL assert_true(JSON_EXTRACT(JSON_EXTRACT(@p, '$**.rows_examined_per_scan'), '$[0]') > 50000, 'range-first index examines tens of thousands of rows');

-- MISTAKE: VARCHAR column compared with a number. MySQL converts every ref_code to a number, so the index is useless.
EXPLAIN FORMAT=JSON INTO @p SELECT * FROM orders WHERE ref_code = 4242;
CALL assert_true(plan_has(@p, 'ALL'), 'implicit conversion forces a full table scan');
CALL assert_true(plan_has(@p, 'orders_ref_code_idx'), 'the index is listed in possible_keys and still not used');

-- MISTAKE: function around the indexed column. DATE(created_at) hides created_at from the index.
EXPLAIN FORMAT=JSON INTO @p SELECT * FROM orders WHERE DATE(created_at) = '2026-03-01';
CALL assert_true(plan_has(@p, 'ALL'), 'function on the indexed column forces a full table scan');

-- Two single-column indexes: index_merge intersection reads about 9000 index entries to return 100 rows.
EXPLAIN FORMAT=JSON INTO @p SELECT id, created_at FROM tickets WHERE queue_id = 7 AND agent_id = 3;
CALL assert_true(plan_has(@p, 'index_merge'), 'AND of two single-column indexes becomes an index merge');

-- Same direction for both sort columns: filesort.
EXPLAIN FORMAT=JSON INTO @p SELECT id, priority, created_at FROM tickets WHERE queue_id = 7 ORDER BY priority ASC, created_at DESC LIMIT 20;
CALL assert_true(JSON_CONTAINS(JSON_EXTRACT(@p, '$**.using_filesort'), 'true'), 'all-ascending index cannot serve the mixed ORDER BY');

-- The redundant index shows up with a ready-made DROP statement.
SELECT redundant_index_name, dominant_index_name, sql_drop_index FROM sys.schema_redundant_indexes WHERE table_schema = DATABASE();
CALL assert_true((SELECT COUNT(*) FROM sys.schema_redundant_indexes WHERE table_schema = DATABASE() AND redundant_index_name = 'orders_created_idx' AND dominant_index_name = 'orders_created_customer_idx') = 1, 'orders_created_idx is reported as redundant');

-- The wrong predicates still return the right rows; only the cost differs.
CALL assert_true((SELECT COUNT(*) FROM orders WHERE ref_code = 4242) = 1, 'numeric comparison finds the row the slow way');
CALL assert_true((SELECT COUNT(*) FROM orders WHERE DATE(created_at) = '2026-03-01') = 1440, 'DATE() finds the day the slow way');
