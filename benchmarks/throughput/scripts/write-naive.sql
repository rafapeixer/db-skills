-- Create an order with three items, one statement per round trip inside an
-- explicit transaction. 6 round trips, the connection held for all of them.
\set c random(1, 20000)
BEGIN;
INSERT INTO orders (customer_id, status, total) VALUES (:c, 'new', 30.00) RETURNING id \gset
INSERT INTO order_items (order_id, sku, qty) VALUES (:id, 'A1', 1);
INSERT INTO order_items (order_id, sku, qty) VALUES (:id, 'B1', 2);
INSERT INTO order_items (order_id, sku, qty) VALUES (:id, 'C1', 3);
COMMIT;
