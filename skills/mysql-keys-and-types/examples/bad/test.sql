-- Bad: the schema written from habit. INT and CHAR(36) or random keys,
-- utf8mb3, local DATETIME and TIMESTAMP, DOUBLE money, nullable columns,
-- no foreign keys, business data inside JSON, and strict mode switched off.
-- The assertions describe what goes wrong.
SET NAMES utf8mb4;

-- MISTAKE: INT AUTO_INCREMENT stops at 2147483647, and widening it later copies the table.
CREATE TABLE customers (
  id INT AUTO_INCREMENT PRIMARY KEY,
  -- MISTAKE: utf8mb3 (the old "utf8") cannot store 4-byte characters such as emoji.
  name VARCHAR(100) CHARACTER SET utf8mb3,
  email VARCHAR(20),
  -- MISTAKE: DATETIME DEFAULT CURRENT_TIMESTAMP records the session's local wall-clock time.
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  -- MISTAKE: TIMESTAMP ends at 2038-01-19 03:14:07 UTC.
  trial_ends_at TIMESTAMP NULL
);

CREATE TABLE orders (
  -- MISTAKE: a CHAR(36) UUID key is 36 bytes, and every secondary index repeats it.
  id CHAR(36) NOT NULL DEFAULT (UUID()) PRIMARY KEY,
  -- MISTAKE: no FOREIGN KEY and no NOT NULL; orphans and missing values get in.
  customer_id INT,
  status VARCHAR(16),
  -- MISTAKE: DOUBLE cannot represent 0.10 exactly; the CHECK lets NULL through.
  total DOUBLE CHECK (total >= 0),
  -- MISTAKE: business fields live only inside JSON, with no types and no index.
  details JSON
);

-- utf8mb3 refuses an emoji (error 1366).
CALL assert_error('INSERT INTO customers (name) VALUES (CONCAT(''Ana '', _utf8mb4 X''F09F9880''))', 'HY000',
  'utf8mb3 refuses a 4-byte character');

-- TIMESTAMP cannot hold a trial that ends in 2039 (error 1292).
CALL assert_error('INSERT INTO customers (name, trial_ends_at) VALUES (''Bia'', ''2039-01-01 00:00:00'')', '22007',
  'TIMESTAMP refuses a value after 2038-01-19 03:14:07 UTC');

-- The same instant, written from sessions in two time zones, is stored 12 hours apart.
SET timestamp = UNIX_TIMESTAMP('2026-03-01 12:00:00');
SET time_zone = '-03:00';
INSERT INTO customers (name) VALUES ('Sao Paulo writer');
SET time_zone = '+09:00';
INSERT INTO customers (name) VALUES ('Tokyo writer');
SET time_zone = '+00:00';
SET timestamp = DEFAULT;
CALL assert_true((SELECT TIMESTAMPDIFF(HOUR, MIN(created_at), MAX(created_at)) FROM customers
  WHERE name LIKE '% writer') = 12,
  'DATETIME DEFAULT CURRENT_TIMESTAMP stores one instant as 09:00 and 21:00');

-- MISTAKE: strict mode switched off (an old my.cnf, or an ORM that sets sql_mode = '').
SET SESSION sql_mode = '';
INSERT INTO customers (name, email, trial_ends_at) VALUES ('Carla', 'carla.long.name@example.com', '2039-01-01 00:00:00');
CALL assert_true((SELECT email FROM customers WHERE name = 'Carla') = 'carla.long.name@exam',
  'without strict mode a long email is cut to 20 characters with only a warning');
CALL assert_true((SELECT CAST(trial_ends_at AS CHAR) FROM customers WHERE name = 'Carla') = '0000-00-00 00:00:00',
  'without strict mode a 2039 TIMESTAMP silently becomes 0000-00-00');
INSERT INTO orders (customer_id, status, total) VALUES (1, 'paid', 'abc');
CALL assert_true((SELECT total FROM orders WHERE customer_id = 1) = 0,
  'without strict mode a total of abc is stored as 0');
SET SESSION sql_mode = DEFAULT;
DELETE FROM orders;

-- The INT key runs out.
INSERT INTO customers (id, name) VALUES (2147483647, 'Last');
CALL assert_error('INSERT INTO customers (name) VALUES (''One more'')', '23000',
  'INT AUTO_INCREMENT cannot go past 2147483647: duplicate key on the next insert');

-- DOUBLE money does not add up.
INSERT INTO orders (customer_id, status, total, details)
WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10)
SELECT 1, 'paid', 0.10, JSON_OBJECT('channel', 'web') FROM n;
CALL assert_true((SELECT SUM(total) FROM orders) <> 1,
  'DOUBLE sums ten 0.10 to 0.9999999999999999, not 1');

-- A NULL total passes the CHECK and drops out of both halves of a report;
-- an order for a customer that does not exist is stored.
INSERT INTO orders (customer_id, status, total) VALUES (999, 'paid', NULL);
CALL assert_true((SELECT COUNT(*) FROM orders WHERE total >= 0) + (SELECT COUNT(*) FROM orders WHERE total < 0)
  < (SELECT COUNT(*) FROM orders), 'a NULL total is in neither total >= 0 nor total < 0');
CALL assert_true((SELECT COUNT(*) FROM orders o LEFT JOIN customers c ON c.id = o.customer_id
  WHERE o.customer_id = 999 AND c.id IS NULL) = 1,
  'without a foreign key an orphan order is stored');

-- JSON accepts a total of "abc", and a filter on a JSON key scans the table.
INSERT INTO orders (customer_id, status, total, details) VALUES (1, 'paid', 5, '{"channel": "web", "total": "abc"}');
CALL assert_true((SELECT COUNT(*) FROM orders WHERE details->>'$.total' = 'abc') = 1,
  'JSON stores a non-numeric total without complaint');
EXPLAIN FORMAT=JSON INTO @plan SELECT id FROM orders WHERE details->>'$.channel' = 'web';
CALL assert_true(plan_has(@plan, 'ALL') OR plan_has(@plan, 'table'),
  'filtering on a JSON key with no generated column is a full table scan');

-- MISTAKE: a foreign key to a non-unique column, copied from an 8.0 schema.
CREATE TABLE regions (id BIGINT PRIMARY KEY, code VARCHAR(8) NOT NULL, KEY regions_code_idx (code));
CALL assert_error('CREATE TABLE stores (id BIGINT PRIMARY KEY, region_code VARCHAR(8) NOT NULL, FOREIGN KEY (region_code) REFERENCES regions (code))', 'HY000',
  'MySQL 8.4+ refuses a foreign key to a non-unique key (error 6125)');
SET SESSION restrict_fk_on_non_standard_key = OFF;
CREATE TABLE stores (id BIGINT PRIMARY KEY, region_code VARCHAR(8) NOT NULL, FOREIGN KEY (region_code) REFERENCES regions (code));
SET @fk_warnings = @@warning_count;
SET SESSION restrict_fk_on_non_standard_key = DEFAULT;
CALL assert_true(@fk_warnings > 0, 'turning the restriction off only trades the error for a deprecation warning');

-- Key size and page fill, 200000 rows each. Baselines first.
CREATE TABLE ev_bigint (id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY, email VARCHAR(40) NOT NULL, KEY (email));
CREATE TABLE ev_ordered (id BINARY(16) PRIMARY KEY, email VARCHAR(40) NOT NULL);
-- MISTAKE: CHAR(36) UUID text as the primary key.
CREATE TABLE ev_char36 (id CHAR(36) PRIMARY KEY, email VARCHAR(40) NOT NULL, KEY (email));
-- MISTAKE: random (version 4) UUIDs from the application, simulated with RANDOM_BYTES(16).
CREATE TABLE ev_random (id BINARY(16) PRIMARY KEY, email VARCHAR(40) NOT NULL);
-- MISTAKE: UUID_TO_BIN(UUID()) without the swap flag puts the fast-changing time-low first.
CREATE TABLE ev_v1_unswapped (id BINARY(16) PRIMARY KEY, email VARCHAR(40) NOT NULL);

INSERT INTO ev_bigint (email)
WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200000)
SELECT CONCAT('user', i, '@example.com') FROM n;
INSERT INTO ev_char36
WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200000)
SELECT UUID(), CONCAT('user', i, '@example.com') FROM n;
INSERT INTO ev_random
WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200000)
SELECT RANDOM_BYTES(16), CONCAT('user', i, '@example.com') FROM n;

-- Version 1 UUIDs as a server creates them at one row per second for 2.3 days:
-- the 60-bit timestamp counts 100 ns steps, and time-low wraps every 429 seconds.
-- One burst of UUID() calls in a test never wraps, so the timestamps are built here.
CREATE TEMPORARY TABLE v1 AS
WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200000)
SELECT i, CONCAT(LPAD(HEX(ts & 0xFFFFFFFF), 8, '0'), '-', LPAD(HEX((ts >> 32) & 0xFFFF), 4, '0'), '-',
  LPAD(HEX(((ts >> 48) & 0x0FFF) | 0x1000), 4, '0'), '-8d6e-56aba3015c5d') AS u
FROM (SELECT i, 139000000000000000 + i * 10000000 AS ts FROM n) t;
CALL assert_true((SELECT COUNT(*) FROM v1 WHERE IS_UUID(u)) = 200000, 'the simulated values are valid UUIDs');
INSERT INTO ev_ordered SELECT UUID_TO_BIN(u, 1), CONCAT('user', i, '@example.com') FROM v1 ORDER BY i;
INSERT INTO ev_v1_unswapped SELECT UUID_TO_BIN(u), CONCAT('user', i, '@example.com') FROM v1 ORDER BY i;
ANALYZE TABLE ev_bigint, ev_ordered, ev_char36, ev_random, ev_v1_unswapped;

CREATE TEMPORARY TABLE leaf AS
SELECT table_name, index_name, stat_value AS pages FROM mysql.innodb_index_stats
WHERE database_name = DATABASE() AND table_name LIKE 'ev\_%' AND stat_name = 'n_leaf_pages';
SELECT * FROM leaf ORDER BY table_name, index_name;
SET @bigint_pk = (SELECT pages FROM leaf WHERE table_name = 'ev_bigint' AND index_name = 'PRIMARY');
SET @bigint_email = (SELECT pages FROM leaf WHERE table_name = 'ev_bigint' AND index_name = 'email');
SET @char36_pk = (SELECT pages FROM leaf WHERE table_name = 'ev_char36' AND index_name = 'PRIMARY');
SET @char36_email = (SELECT pages FROM leaf WHERE table_name = 'ev_char36' AND index_name = 'email');
SET @ordered_pk = (SELECT pages FROM leaf WHERE table_name = 'ev_ordered' AND index_name = 'PRIMARY');
SET @random_pk = (SELECT pages FROM leaf WHERE table_name = 'ev_random' AND index_name = 'PRIMARY');
SET @unswapped_pk = (SELECT pages FROM leaf WHERE table_name = 'ev_v1_unswapped' AND index_name = 'PRIMARY');

CALL assert_true(@char36_pk > @bigint_pk * 1.5, 'a CHAR(36) primary key is over 50% larger than BIGINT');
CALL assert_true(@char36_email > @bigint_email * 1.5,
  'the email index is over 50% larger because every entry carries the 36-byte key');
CALL assert_true(@random_pk > @ordered_pk * 1.3,
  'random 16-byte keys need over 30% more leaf pages than the same size inserted in order');
CALL assert_true(@unswapped_pk > @ordered_pk * 1.2,
  'unswapped v1 UUIDs need over 20% more leaf pages than the same UUIDs swapped');
