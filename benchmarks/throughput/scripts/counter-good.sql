-- Each sale decrements one of 16 shards picked at random; the total is
-- SUM(qty) over the shards. Contention drops by the number of shards.
\set s random(0, 15)
UPDATE stock_shards SET qty = qty - 1 WHERE sku = 'SKU-1' AND shard = :s;
