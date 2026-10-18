-- One API request: a customer's latest 10 orders, then each order's items
-- in its own query (N+1). 11 round trips.
function thread_init()
  con = sysbench.sql.driver():connect()
  -- The order ids drive the item queries, so this query is read as rows.
  -- sysbench cannot read rows from a server-side prepared statement, so it
  -- goes over the text protocol; it is still one round trip.
  orders_sql = "SELECT id, status, total, created_at FROM orders WHERE customer_id = %d " ..
               "ORDER BY created_at DESC, id DESC LIMIT 10"
  items = con:prepare("SELECT sku, qty FROM order_items WHERE order_id = ?")
  order_id = items:bind_create(sysbench.sql.type.BIGINT)
  items:bind_param(order_id)
end

function event()
  local rs = con:query(string.format(orders_sql, sysbench.rand.uniform(1, 20000)))
  local ids = {}
  for i = 1, rs.nrows do ids[i] = rs:fetch_row()[1] end
  rs:free()
  for i = 1, #ids do
    order_id:set(tonumber(ids[i]))
    items:execute()
  end
end

function thread_done()
  items:close()
  con:disconnect()
end
