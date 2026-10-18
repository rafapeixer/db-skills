-- The same order in one statement (implicitly one transaction). 1 round trip.
\set c random(1, 20000)
WITH o AS (INSERT INTO orders (customer_id, status, total) VALUES (:c, 'new', 30.00) RETURNING id)
INSERT INTO order_items (order_id, sku, qty)
SELECT o.id, v.sku, v.qty FROM o, (VALUES ('A1', 1), ('B1', 2), ('C1', 3)) AS v(sku, qty);
