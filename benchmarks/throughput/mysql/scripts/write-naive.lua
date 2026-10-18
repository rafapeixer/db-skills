-- Create an order with three items, one statement per round trip inside an
-- explicit transaction. 6 round trips, the connection held for all of them.
-- order_items has no AUTO_INCREMENT column, so LAST_INSERT_ID() keeps the
-- order's id for the whole transaction.
function thread_init()
  con = sysbench.sql.driver():connect()
  ins_order = con:prepare("INSERT INTO orders (customer_id, status, total) VALUES (?, 'new', 30.00)")
  customer = ins_order:bind_create(sysbench.sql.type.BIGINT)
  ins_order:bind_param(customer)
  ins_a = con:prepare("INSERT INTO order_items (order_id, sku, qty) VALUES (LAST_INSERT_ID(), 'A1', 1)")
  ins_b = con:prepare("INSERT INTO order_items (order_id, sku, qty) VALUES (LAST_INSERT_ID(), 'B1', 2)")
  ins_c = con:prepare("INSERT INTO order_items (order_id, sku, qty) VALUES (LAST_INSERT_ID(), 'C1', 3)")
end

function event()
  con:query("BEGIN")
  customer:set(sysbench.rand.uniform(1, 20000))
  ins_order:execute()
  ins_a:execute()
  ins_b:execute()
  ins_c:execute()
  con:query("COMMIT")
end

function thread_done()
  ins_order:close(); ins_a:close(); ins_b:close(); ins_c:close()
  con:disconnect()
end
