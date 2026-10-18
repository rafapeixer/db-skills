-- The same API request in one statement: the page and its items. 1 round trip.
\set c random(1, 20000)
SELECT o.id, o.status, o.total, o.created_at, i.skus, i.qtys
FROM (SELECT id, status, total, created_at FROM orders WHERE customer_id = :c ORDER BY created_at DESC, id DESC LIMIT 10) o
LEFT JOIN LATERAL (SELECT array_agg(sku ORDER BY sku) AS skus, array_agg(qty ORDER BY sku) AS qtys FROM order_items WHERE order_id = o.id) i ON true
ORDER BY o.created_at DESC, o.id DESC;
