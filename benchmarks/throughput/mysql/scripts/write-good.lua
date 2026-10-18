-- The same order with the items in one multi-row INSERT. MySQL has no
-- INSERT ... RETURNING or data-modifying CTE, so the order and its items stay
-- two statements, joined by LAST_INSERT_ID() on the server, inside one
-- transaction: 4 round trips instead of 6 (PostgreSQL needs 1).
function thread_init()
  con = sysbench.sql.driver():connect()
  ins_order = con:prepare("INSERT INTO orders (customer_id, status, total) VALUES (?, 'new', 30.00)")
  customer = ins_order:bind_create(sysbench.sql.type.BIGINT)
  ins_order:bind_param(customer)
  ins_items = con:prepare("INSERT INTO order_items (order_id, sku, qty) VALUES " ..
                          "(LAST_INSERT_ID(), 'A1', 1), (LAST_INSERT_ID(), 'B1', 2), (LAST_INSERT_ID(), 'C1', 3)")
end

function event()
  con:query("BEGIN")
  customer:set(sysbench.rand.uniform(1, 20000))
  ins_order:execute()
  ins_items:execute()
  con:query("COMMIT")
end

function thread_done()
  ins_order:close(); ins_items:close()
  con:disconnect()
end
