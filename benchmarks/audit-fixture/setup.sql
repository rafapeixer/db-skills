-- A small shop database with ten problems planted on purpose. The audit
-- eval exports its statistics views and asks an agent to find them.

CREATE TABLE customers (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email      text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Problem: orders.customer_id has a foreign key but no index, so every
-- DELETE FROM customers scans orders.
CREATE TABLE orders (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers (id),
  status      text NOT NULL,
  total       numeric(12, 2) NOT NULL,
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE order_items (
  order_id bigint NOT NULL REFERENCES orders (id),
  sku      text NOT NULL,
  qty      int NOT NULL,
  PRIMARY KEY (order_id, sku)
);

-- Problem: random UUID primary key on a high-insert table.
CREATE TABLE events (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id bigint NOT NULL,
  type       text NOT NULL,
  payload    jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Problem: orders_status is a prefix duplicate of orders_status_created.
CREATE INDEX orders_status ON orders (status);
CREATE INDEX orders_status_created ON orders (status, created_at);
-- Problem: orders_total is never used.
CREATE INDEX orders_total ON orders (total);
CREATE INDEX orders_created ON orders (created_at);

-- Problem: autovacuum switched off on the busiest table.
ALTER TABLE orders SET (autovacuum_enabled = false);

INSERT INTO customers (email, created_at)
SELECT 'c' || g || '@example.com', now() - (g || ' minutes')::interval
FROM generate_series(1, 20000) g;

INSERT INTO orders (customer_id, status, total, created_at)
SELECT 1 + (g % 20000), (ARRAY['new', 'paid', 'shipped', 'cancelled'])[1 + g % 4], (g % 500) + 0.99,
       now() - (g || ' seconds')::interval
FROM generate_series(1, 300000) g;

INSERT INTO order_items (order_id, sku, qty)
SELECT o.id, s.sku || (o.id % 300), 1 + o.id % 3
FROM orders o CROSS JOIN (VALUES ('A'), ('B')) AS s(sku);

INSERT INTO events (account_id, type, payload)
SELECT g % 500, 'page_view', jsonb_build_object('n', g)
FROM generate_series(1, 100000) g;

ANALYZE;
