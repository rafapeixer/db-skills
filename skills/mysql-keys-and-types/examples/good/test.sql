-- Good: short, insert-ordered primary keys (BIGINT AUTO_INCREMENT, or a
-- UUID stored as BINARY(16) with its time parts swapped), utf8mb4, DATETIME
-- in UTC, DECIMAL money, strict mode, NOT NULL and CHECK by default, foreign
-- keys to primary keys, and JSON only for attributes with no fixed shape.
SET NAMES utf8mb4;

CREATE TABLE customers (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(254) NOT NULL,
  name VARCHAR(100) NOT NULL,
  created_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
  CONSTRAINT customers_email_uq UNIQUE (email),
  CONSTRAINT customers_email_len CHECK (CHAR_LENGTH(email) >= 3)
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

CREATE TABLE orders (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  customer_id BIGINT UNSIGNED NOT NULL,
  status VARCHAR(16) NOT NULL,
  total DECIMAL(12, 2) NOT NULL,
  placed_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
  attributes JSON NOT NULL DEFAULT (JSON_OBJECT()),
  -- The one JSON key that queries filter on, promoted to an indexed column.
  channel VARCHAR(20) GENERATED ALWAYS AS (attributes->>'$.channel') VIRTUAL,
  CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id) REFERENCES customers (id),
  CONSTRAINT orders_status_chk CHECK (status IN ('pending', 'paid', 'shipped')),
  CONSTRAINT orders_total_chk CHECK (total >= 0),
  KEY orders_channel_idx (channel)
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- Rule 3: utf8mb4 stores 4-byte characters, and the default _ai_ci
-- collation treats emails that differ only in case as the same value.
INSERT INTO customers (email, name) VALUES ('ana@example.com', CONCAT('Ana ', _utf8mb4 X'F09F9880'));
INSERT INTO customers (email, name) VALUES ('bruno@example.com', 'Bruno');
CALL assert_true((SELECT LENGTH(name) - CHAR_LENGTH(name) FROM customers WHERE id = 1) = 3,
  'utf8mb4 stores the emoji as one 4-byte character');
CALL assert_true((SELECT COUNT(*) FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'customers' AND column_name = 'email'
    AND collation_name = 'utf8mb4_0900_ai_ci') = 1,
  'email uses utf8mb4_0900_ai_ci');
CALL assert_error('INSERT INTO customers (email, name) VALUES (''ANA@example.com'', ''Ana'')', '23000',
  'the case-insensitive unique key refuses ANA@ when ana@ exists');

-- Rule 4: two writers in different session time zones record one instant in UTC.
SET timestamp = UNIX_TIMESTAMP('2026-03-01 12:00:00');
SET time_zone = '-03:00';
INSERT INTO orders (customer_id, status, total) VALUES (1, 'paid', 0.10);
SET time_zone = '+09:00';
INSERT INTO orders (customer_id, status, total) VALUES (1, 'paid', 0.10);
SET time_zone = '+00:00';
SET timestamp = DEFAULT;
CALL assert_true((SELECT COUNT(DISTINCT placed_at) FROM orders) = 1,
  'UTC_TIMESTAMP(6) stores one value for the same instant from -03:00 and +09:00');
CALL assert_true((SELECT MIN(placed_at) FROM orders) = '2026-03-01 12:00:00',
  'the stored value is 12:00 UTC whatever the session time_zone was');
-- DATETIME has no 2038 limit.
INSERT INTO orders (customer_id, status, total, placed_at) VALUES (2, 'pending', 0.10, '2040-01-01 00:00:00');
CALL assert_true((SELECT COUNT(*) FROM orders WHERE placed_at = '2040-01-01 00:00:00') = 1,
  'DATETIME stores dates after 2038-01-19');

-- Rule 5: ten totals of 0.10 add up to exactly 1.00.
INSERT INTO orders (customer_id, status, total)
WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 7)
SELECT 2, 'paid', 0.10 FROM n;
CALL assert_true((SELECT SUM(total) FROM orders) = 1.00,
  'DECIMAL sums money exactly: 10 x 0.10 = 1.00');

-- Rule 6: strict mode (the default) and constraints refuse every invalid row.
CALL assert_true(FIND_IN_SET('STRICT_TRANS_TABLES', @@SESSION.sql_mode) > 0,
  'the session runs with STRICT_TRANS_TABLES');
CALL assert_error('INSERT INTO orders (customer_id, status, total) VALUES (1, ''paid'', NULL)', '23000',
  'NOT NULL refuses an order without a total');
CALL assert_error('INSERT INTO orders (customer_id, status, total) VALUES (1, ''paid'', -5)', 'HY000',
  'CHECK refuses a negative total (error 3819)');
CALL assert_error('INSERT INTO orders (customer_id, status, total) VALUES (1, ''payed'', 5)', 'HY000',
  'CHECK refuses a misspelled status (error 3819)');
CALL assert_error('INSERT INTO orders (customer_id, status, total) VALUES (1, ''paid'', ''abc'')', 'HY000',
  'strict mode refuses a total that is not a number (error 1366)');
CALL assert_error('INSERT INTO customers (email, name) VALUES (REPEAT(''a'', 300), ''Long'')', '22001',
  'strict mode refuses a 300-character email instead of truncating it');
CALL assert_error('INSERT INTO customers (email, name) VALUES ('''', ''Empty'')', 'HY000',
  'the length CHECK refuses an empty email');

-- Rule 7: the foreign key refuses orphans, and InnoDB indexed the child column.
CALL assert_error('INSERT INTO orders (customer_id, status, total) VALUES (999, ''paid'', 5)', '23000',
  'the foreign key refuses an order for a customer that does not exist');
CALL assert_true((SELECT COUNT(*) FROM information_schema.statistics
  WHERE table_schema = DATABASE() AND table_name = 'orders'
    AND column_name = 'customer_id' AND seq_in_index = 1) = 1,
  'orders.customer_id leads an index, created by InnoDB for the foreign key');

-- Rule 8: JSON is validated, and the promoted key is served by its index.
CALL assert_error('INSERT INTO orders (customer_id, status, total, attributes) VALUES (1, ''paid'', 5, ''{bad'')', '22032',
  'the JSON type refuses an invalid document');
UPDATE orders SET attributes = JSON_OBJECT('channel', 'web', 'gift', TRUE) WHERE id = 1;
EXPLAIN FORMAT=JSON INTO @plan SELECT id FROM orders WHERE channel = 'web';
CALL assert_true(plan_has(@plan, 'orders_channel_idx'), 'the generated column is searched through its index');
EXPLAIN FORMAT=JSON INTO @plan SELECT id FROM orders WHERE attributes->>'$.channel' = 'web';
CALL assert_true(plan_has(@plan, 'orders_channel_idx'),
  'the optimizer matches the JSON expression to the indexed generated column');

-- Rules 1 and 2: 200000 sequential BIGINT keys against 200000 UUID() keys
-- stored with UUID_TO_BIN(UUID(), 1). Both are insert-ordered.
CREATE TABLE events_bigint (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  payload VARCHAR(40) NOT NULL
);
CREATE TABLE events_uuid (
  id BINARY(16) NOT NULL DEFAULT (UUID_TO_BIN(UUID(), 1)) PRIMARY KEY,
  payload VARCHAR(40) NOT NULL
);
INSERT INTO events_bigint (payload)
WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200000)
SELECT CONCAT('event ', i) FROM n;
INSERT INTO events_uuid (payload)
WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200000)
SELECT CONCAT('event ', i) FROM n;
ANALYZE TABLE events_bigint, events_uuid;

SET @bigint_leaf = (SELECT stat_value FROM mysql.innodb_index_stats
  WHERE database_name = DATABASE() AND table_name = 'events_bigint'
    AND index_name = 'PRIMARY' AND stat_name = 'n_leaf_pages');
SET @uuid_leaf = (SELECT stat_value FROM mysql.innodb_index_stats
  WHERE database_name = DATABASE() AND table_name = 'events_uuid'
    AND index_name = 'PRIMARY' AND stat_name = 'n_leaf_pages');
SELECT @bigint_leaf AS bigint_leaf_pages, @uuid_leaf AS swapped_uuid_leaf_pages;
CALL assert_true(@uuid_leaf < @bigint_leaf * 1.3,
  'swapped UUID keys fill pages like BIGINT: only the 8 extra bytes per row cost space');

-- Read the key back with the same swap flag it was written with.
SET @u = UUID();
INSERT INTO events_uuid (id, payload) VALUES (UUID_TO_BIN(@u, 1), 'round trip');
CALL assert_true((SELECT BIN_TO_UUID(id, 1) FROM events_uuid WHERE payload = 'round trip') = @u,
  'BIN_TO_UUID(id, 1) returns the UUID that UUID_TO_BIN(u, 1) stored');
CALL assert_true((SELECT COUNT(*) FROM events_uuid WHERE id = UUID_TO_BIN(@u, 1)) = 1,
  'lookups convert the parameter with the same flag');
