-- One API request: a customer's latest 10 orders, then each order's items
-- in its own query (N+1). 11 round trips.
\set c random(1, 20000)
SELECT id, status, total, created_at FROM orders WHERE customer_id = :c ORDER BY created_at DESC, id DESC LIMIT 10;
SELECT sku, qty FROM order_items WHERE order_id = (SELECT id FROM orders WHERE customer_id = :c ORDER BY created_at DESC, id DESC OFFSET 0 LIMIT 1);
SELECT sku, qty FROM order_items WHERE order_id = (SELECT id FROM orders WHERE customer_id = :c ORDER BY created_at DESC, id DESC OFFSET 1 LIMIT 1);
SELECT sku, qty FROM order_items WHERE order_id = (SELECT id FROM orders WHERE customer_id = :c ORDER BY created_at DESC, id DESC OFFSET 2 LIMIT 1);
SELECT sku, qty FROM order_items WHERE order_id = (SELECT id FROM orders WHERE customer_id = :c ORDER BY created_at DESC, id DESC OFFSET 3 LIMIT 1);
SELECT sku, qty FROM order_items WHERE order_id = (SELECT id FROM orders WHERE customer_id = :c ORDER BY created_at DESC, id DESC OFFSET 4 LIMIT 1);
SELECT sku, qty FROM order_items WHERE order_id = (SELECT id FROM orders WHERE customer_id = :c ORDER BY created_at DESC, id DESC OFFSET 5 LIMIT 1);
SELECT sku, qty FROM order_items WHERE order_id = (SELECT id FROM orders WHERE customer_id = :c ORDER BY created_at DESC, id DESC OFFSET 6 LIMIT 1);
SELECT sku, qty FROM order_items WHERE order_id = (SELECT id FROM orders WHERE customer_id = :c ORDER BY created_at DESC, id DESC OFFSET 7 LIMIT 1);
SELECT sku, qty FROM order_items WHERE order_id = (SELECT id FROM orders WHERE customer_id = :c ORDER BY created_at DESC, id DESC OFFSET 8 LIMIT 1);
SELECT sku, qty FROM order_items WHERE order_id = (SELECT id FROM orders WHERE customer_id = :c ORDER BY created_at DESC, id DESC OFFSET 9 LIMIT 1);
