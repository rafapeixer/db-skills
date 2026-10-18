-- The same API request in one statement: the page and its items, the items
-- aggregated per order by a LATERAL derived table (MySQL 8.0.14+). 1 round trip.
function thread_init()
  con = sysbench.sql.driver():connect()
  page = con:prepare([[
SELECT o.id, o.status, o.total, o.created_at, i.items
FROM (SELECT id, status, total, created_at FROM orders WHERE customer_id = ?
      ORDER BY created_at DESC, id DESC LIMIT 10) o
LEFT JOIN LATERAL (SELECT JSON_ARRAYAGG(JSON_OBJECT('sku', sku, 'qty', qty)) AS items
                   FROM order_items WHERE order_id = o.id) i ON TRUE
ORDER BY o.created_at DESC, o.id DESC]])
  customer = page:bind_create(sysbench.sql.type.BIGINT)
  page:bind_param(customer)
end

function event()
  customer:set(sysbench.rand.uniform(1, 20000))
  page:execute()
end

function thread_done()
  page:close()
  con:disconnect()
end
