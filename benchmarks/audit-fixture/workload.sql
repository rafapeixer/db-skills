-- Production-like traffic that leaves the planted problems visible in the
-- statistics views. Statements use bind-style literals so
-- pg_stat_statements normalizes them the way an application's would.

-- Problem: deep OFFSET pagination is the most expensive statement.
DO $$
BEGIN
  FOR i IN 1..300 LOOP
    PERFORM id, customer_id, status, total, created_at FROM orders
    ORDER BY created_at DESC LIMIT 20 OFFSET (i * 500);
  END LOOP;
END $$;

-- Problem: N+1, one items query per order on every page.
DO $$
DECLARE
  o record;
BEGIN
  FOR o IN SELECT id FROM orders ORDER BY id DESC LIMIT 6000 LOOP
    PERFORM sku, qty FROM order_items WHERE order_id = o.id;
  END LOOP;
END $$;

-- Problem: deleting customers scans orders (no index on the FK column).
DO $$
BEGIN
  FOR i IN 1..40 LOOP
    DELETE FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE customer_id = 19000 + i);
    DELETE FROM orders WHERE customer_id = 19000 + i;
    DELETE FROM customers WHERE id = 19000 + i;
  END LOOP;
END $$;

-- Dead rows on orders: status updates with autovacuum off.
UPDATE orders SET status = 'shipped' WHERE id % 3 = 0 AND status = 'paid';
UPDATE orders SET note = 'checked' WHERE id % 5 = 0;

-- High insert rate on events (random UUID keys).
DO $$
BEGIN
  FOR i IN 1..200 LOOP
    INSERT INTO events (account_id, type, payload)
    SELECT g % 500, 'click', jsonb_build_object('i', i) FROM generate_series(1, 250) g;
  END LOOP;
END $$;

-- Ordinary indexed reads.
DO $$
BEGIN
  FOR i IN 1..2000 LOOP
    PERFORM id FROM orders WHERE status = 'new' AND created_at > now() - interval '1 hour' LIMIT 10;
    PERFORM id FROM customers WHERE email = 'c' || i || '@example.com';
  END LOOP;
END $$;
