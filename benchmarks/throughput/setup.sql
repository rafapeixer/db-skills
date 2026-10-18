-- Shop schema for the throughput benchmark: properly indexed, so the only
-- difference between variants is how the application talks to the database.
CREATE TABLE customers (
  id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email text NOT NULL UNIQUE
);
CREATE TABLE orders (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers (id),
  status      text NOT NULL,
  total       numeric(12, 2) NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_created ON orders (customer_id, created_at DESC, id DESC);
CREATE TABLE order_items (
  order_id bigint NOT NULL REFERENCES orders (id),
  sku      text NOT NULL,
  qty      int NOT NULL,
  PRIMARY KEY (order_id, sku)
);
-- Work queue.
CREATE TABLE jobs (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  status     text NOT NULL DEFAULT 'pending',
  claimed_at timestamptz
);
CREATE INDEX jobs_pending ON jobs (id) WHERE status = 'pending';
-- Hot counter: one row per product (naive) and 16 shards per product (good).
CREATE TABLE stock (sku text PRIMARY KEY, qty bigint NOT NULL);
CREATE TABLE stock_shards (sku text NOT NULL, shard int NOT NULL, qty bigint NOT NULL, PRIMARY KEY (sku, shard));

INSERT INTO customers (email) SELECT 'c' || g || '@example.com' FROM generate_series(1, 20000) g;
INSERT INTO orders (customer_id, status, total, created_at)
SELECT 1 + (g % 20000), 'paid', (g % 500) + 0.99, now() - (g || ' seconds')::interval
FROM generate_series(1, 300000) g;
INSERT INTO order_items (order_id, sku, qty)
SELECT o.id, s.sku || (o.id % 300), 1 + o.id % 3
FROM orders o CROSS JOIN (VALUES ('A'), ('B'), ('C')) AS s(sku);
INSERT INTO jobs (status) SELECT 'pending' FROM generate_series(1, 2000000);
INSERT INTO stock VALUES ('SKU-1', 1000000000);
INSERT INTO stock_shards SELECT 'SKU-1', s, 62500000 FROM generate_series(0, 15) s;
VACUUM ANALYZE;
