-- Schema changes written as if the table were idle. Each assertion below
-- describes the bad outcome, so this file fails if a mistake stops showing.

CREATE TABLE accounts (
  id    bigint PRIMARY KEY,
  email text
);
CREATE TABLE orders (
  id         bigint PRIMARY KEY,
  account_id int,
  amount     int
);
INSERT INTO accounts SELECT g, 'user' || g || '@example.com' FROM generate_series(1, 1000) g;
UPDATE accounts SET email = 'user1@example.com' WHERE id = 2;
INSERT INTO orders SELECT g, g % 1000 + 1, g % 500 FROM generate_series(1, 100000) g;
ANALYZE accounts;
ANALYZE orders;

CREATE FUNCTION held_locks(rel regclass) RETURNS text
LANGUAGE sql AS $$
  SELECT string_agg(mode, ',' ORDER BY mode) FROM pg_locks
  WHERE locktype = 'relation' AND relation = rel AND pid = pg_backend_pid() AND granted;
$$;
CREATE FUNCTION xact_seq_scans(rel regclass) RETURNS bigint
LANGUAGE sql AS $$
  SELECT coalesce((SELECT seq_scan FROM pg_stat_xact_user_tables WHERE relid = rel), 0);
$$;

CREATE EXTENSION dblink;
SELECT dblink_connect('report', 'dbname=' || current_database());
SELECT dblink_connect('migration', 'dbname=' || current_database());

-- 1. No lock_timeout: the ALTER waits behind a long report, and every
-- query that arrives after it waits behind the ALTER.
SELECT dblink_exec('report', 'BEGIN');
SELECT * FROM dblink('report', 'SELECT count(*) FROM orders') AS r(n bigint);
-- MISTAKE: lock_timeout is 0 (wait forever), so the ALTER queues for its
-- ACCESS EXCLUSIVE lock for as long as the report runs.
SELECT dblink_send_query('migration', 'ALTER TABLE orders ADD COLUMN note text');
DO $$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN EXISTS (SELECT 1 FROM pg_locks
      WHERE relation = 'orders'::regclass AND mode = 'AccessExclusiveLock' AND NOT granted);
    PERFORM pg_sleep(0.05);
  END LOOP;
END
$$;
-- A plain read from the application now waits too (bounded here at 500ms
-- only so the test can observe it).
SET lock_timeout = '500ms';
SELECT assert_error('SELECT count(*) FROM orders WHERE id = 1',
  '55P03', 'a plain SELECT is blocked behind the waiting ALTER');
RESET lock_timeout;
SELECT dblink_exec('report', 'COMMIT');
SELECT * FROM dblink_get_result('migration') AS r(status text);
SELECT dblink_disconnect('report');
SELECT dblink_disconnect('migration');

-- 2. A volatile default rewrites the table and every index.
SELECT pg_relation_filenode('orders') AS orders_node,
       pg_relation_filenode('orders_pkey') AS pkey_node \gset
-- MISTAKE: clock_timestamp() is volatile, so every row gets its own value:
-- full rewrite of the table and its indexes under ACCESS EXCLUSIVE.
ALTER TABLE orders ADD COLUMN created_at timestamptz NOT NULL DEFAULT clock_timestamp();
SELECT assert_true(pg_relation_filenode('orders') <> :orders_node,
  'volatile default rewrote the table');
SELECT assert_true(pg_relation_filenode('orders_pkey') <> :pkey_node,
  'volatile default rebuilt the primary key index');

-- 3. Changing int to bigint in place rewrites the table too.
SELECT pg_relation_filenode('orders') AS orders_node \gset
-- MISTAKE: int -> bigint is not binary coercible: another full rewrite.
ALTER TABLE orders ALTER COLUMN account_id TYPE bigint;
SELECT assert_true(pg_relation_filenode('orders') <> :orders_node,
  'type change rewrote the table');

-- 4. A foreign key added in one step scans orders while it blocks writes
-- on both tables.
BEGIN;
SELECT xact_seq_scans('orders') AS scans_before \gset
-- MISTAKE: no NOT VALID, so the full validation scan runs while
-- SHARE ROW EXCLUSIVE is held on orders and on accounts.
ALTER TABLE orders ADD CONSTRAINT orders_account_id_fkey
  FOREIGN KEY (account_id) REFERENCES accounts (id);
SELECT assert_true(xact_seq_scans('orders') > :scans_before,
  'ADD FOREIGN KEY scanned orders inside the locking statement');
SELECT assert_true(held_locks('accounts') = 'AccessShareLock,RowShareLock,ShareRowExclusiveLock',
  'the referenced table is locked against writes as well');
SELECT assert_error(format('SELECT dblink_exec(%L, %L)',
  'dbname=' || current_database() || ' options=''-c lock_timeout=200''',
  'INSERT INTO accounts VALUES (5000, ''new@example.com'')'),
  '55P03', 'a signup on accounts waits for the migration');
COMMIT;

-- 5. SET NOT NULL with no CHECK proof scans under ACCESS EXCLUSIVE.
BEGIN;
SELECT xact_seq_scans('orders') AS scans_before \gset
-- MISTAKE: no validated CHECK (amount IS NOT NULL) first, so the whole
-- table is scanned while reads and writes are locked out.
ALTER TABLE orders ALTER COLUMN amount SET NOT NULL;
SELECT assert_true(xact_seq_scans('orders') > :scans_before,
  'SET NOT NULL scanned the table');
SELECT assert_true(held_locks('orders') = 'AccessExclusiveLock',
  'and held ACCESS EXCLUSIVE while it did');
COMMIT;

-- 6. A plain CREATE INDEX blocks writes for the whole build.
BEGIN;
-- MISTAKE: no CONCURRENTLY: SHARE lock, inserts and updates wait.
CREATE INDEX orders_created_at_idx ON orders (created_at);
SELECT assert_true(held_locks('orders') = 'ShareLock',
  'CREATE INDEX holds SHARE, which conflicts with writes');
COMMIT;

-- 7. Retrying a failed concurrent build with IF NOT EXISTS keeps the
-- INVALID index.
SELECT dblink_exec('dbname=' || current_database(),
  'CREATE UNIQUE INDEX CONCURRENTLY accounts_email_idx ON accounts (email)', false) AS build \gset
UPDATE accounts SET email = 'user2@example.com' WHERE id = 2;
-- MISTAKE: IF NOT EXISTS sees the invalid index by name and skips the build.
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS accounts_email_idx ON accounts (email);
SELECT assert_true(NOT indisvalid, 'the index is still INVALID: writes maintain it, queries ignore it')
FROM pg_index WHERE indexrelid = 'accounts_email_idx'::regclass;
