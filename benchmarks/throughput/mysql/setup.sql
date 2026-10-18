-- Shop schema for the MySQL throughput benchmark: the same shape and data as
-- ../setup.sql (PostgreSQL), properly indexed, so the only difference between
-- variants is how the application talks to the database.
CREATE TABLE customers (
  id    BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(255) NOT NULL UNIQUE
) ENGINE = InnoDB;
CREATE TABLE orders (
  id          BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  customer_id BIGINT NOT NULL,
  status      VARCHAR(20) NOT NULL,
  total       DECIMAL(12, 2) NOT NULL,
  created_at  DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  KEY orders_customer_created (customer_id, created_at DESC, id DESC),
  CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id) REFERENCES customers (id)
) ENGINE = InnoDB;
CREATE TABLE order_items (
  order_id BIGINT NOT NULL,
  sku      VARCHAR(40) NOT NULL,
  qty      INT NOT NULL,
  PRIMARY KEY (order_id, sku),
  CONSTRAINT order_items_order_fk FOREIGN KEY (order_id) REFERENCES orders (id)
) ENGINE = InnoDB;
-- Work queue. MySQL has no partial indexes, so the claim
-- (WHERE status = 'pending' ORDER BY id LIMIT 1) is served by (status, id).
CREATE TABLE jobs (
  id         BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  status     VARCHAR(20) NOT NULL DEFAULT 'pending',
  claimed_at DATETIME(6) NULL,
  KEY jobs_status_id (status, id)
) ENGINE = InnoDB;
-- Hot counter: one row per product (naive) and 16 shards per product (good).
CREATE TABLE stock (sku VARCHAR(40) NOT NULL PRIMARY KEY, qty BIGINT NOT NULL) ENGINE = InnoDB;
CREATE TABLE stock_shards (
  sku   VARCHAR(40) NOT NULL,
  shard INT NOT NULL,
  qty   BIGINT NOT NULL,
  PRIMARY KEY (sku, shard)
) ENGINE = InnoDB;

-- Numbers 0..999, generated once with a recursive CTE and cross-joined for
-- larger ranges (faster than one 2-million-deep recursion). A regular table,
-- because a TEMPORARY table cannot be referenced twice in one query.
CREATE TABLE seq (n INT NOT NULL PRIMARY KEY) ENGINE = InnoDB;
SET SESSION cte_max_recursion_depth = 1000;
INSERT INTO seq WITH RECURSIVE s (n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM s WHERE n < 999) SELECT n FROM s;

INSERT INTO customers (email)
SELECT CONCAT('c', g, '@example.com')
FROM (SELECT a.n * 1000 + b.n + 1 AS g FROM seq a JOIN seq b WHERE a.n < 20) x
ORDER BY g;
INSERT INTO orders (customer_id, status, total, created_at)
SELECT 1 + (g % 20000), 'paid', (g % 500) + 0.99, NOW(6) - INTERVAL g SECOND
FROM (SELECT a.n * 1000 + b.n + 1 AS g FROM seq a JOIN seq b WHERE a.n < 300) x
ORDER BY g;
INSERT INTO order_items (order_id, sku, qty)
SELECT o.id, CONCAT(s.sku, o.id % 300), 1 + o.id % 3
FROM orders o CROSS JOIN (SELECT 'A' AS sku UNION ALL SELECT 'B' UNION ALL SELECT 'C') s;
INSERT INTO jobs (status)
SELECT 'pending' FROM seq a JOIN seq b JOIN seq c WHERE a.n < 2;
INSERT INTO stock VALUES ('SKU-1', 1000000000);
INSERT INTO stock_shards SELECT 'SKU-1', n, 62500000 FROM seq WHERE n < 16;
DROP TABLE seq;
ANALYZE TABLE customers, orders, order_items, jobs, stock, stock_shards;
