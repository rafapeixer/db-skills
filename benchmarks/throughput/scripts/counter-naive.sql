-- Every sale decrements one hot row: all connections queue on its row lock.
UPDATE stock SET qty = qty - 1 WHERE sku = 'SKU-1';
