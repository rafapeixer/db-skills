-- Every sale decrements one hot row: all connections queue on its row lock.
function thread_init()
  con = sysbench.sql.driver():connect()
  sale = con:prepare("UPDATE stock SET qty = qty - 1 WHERE sku = 'SKU-1'")
end

function event()
  sale:execute()
end

function thread_done()
  sale:close()
  con:disconnect()
end
