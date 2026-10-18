-- Each sale decrements one of 16 shards picked at random; the total is
-- SUM(qty) over the shards. Contention drops by the number of shards.
function thread_init()
  con = sysbench.sql.driver():connect()
  sale = con:prepare("UPDATE stock_shards SET qty = qty - 1 WHERE sku = 'SKU-1' AND shard = ?")
  shard = sale:bind_create(sysbench.sql.type.INT)
  sale:bind_param(shard)
end

function event()
  shard:set(sysbench.rand.uniform(0, 15))
  sale:execute()
end

function thread_done()
  sale:close()
  con:disconnect()
end
