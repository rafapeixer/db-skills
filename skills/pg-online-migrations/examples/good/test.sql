-- Online schema changes: every step below either touches only the catalog
-- or holds a lock that lets reads and writes continue. psql runs this file
-- statement by statement in autocommit mode (no -1), so a top-level
-- CREATE INDEX CONCURRENTLY is outside any transaction block, as in a
-- migration file marked to run without a transaction.

CREATE TABLE accounts (
  id    bigint PRIMARY KEY,
  email text
);
CREATE TABLE orders (
  id         bigint PRIMARY KEY,
  account_id bigint,
  amount     int
);
INSERT INTO accounts SELECT g, 'user' || g || '@example.com' FROM generate_series(1, 1000) g;
-- One duplicate email, so the first unique index build fails.
UPDATE accounts SET email = 'user1@example.com' WHERE id = 2;
INSERT INTO orders SELECT g, g % 1000 + 1, g % 500 FROM generate_series(1, 100000) g;
ANALYZE accounts;
ANALYZE orders;

-- Relation-level locks this session holds right now.
CREATE FUNCTION held_locks(rel regclass) RETURNS text
LANGUAGE sql AS $$
  SELECT string_agg(mode, ',' ORDER BY mode) FROM pg_locks
  WHERE locktype = 'relation' AND relation = rel AND pid = pg_backend_pid() AND granted;
$$;

-- Sequential scans of a table in the current transaction (counters are
-- not flushed while a transaction is open, so a delta inside one is exact).
CREATE FUNCTION xact_seq_scans(rel regclass) RETURNS bigint
LANGUAGE sql AS $$
  SELECT coalesce((SELECT seq_scan FROM pg_stat_xact_user_tables WHERE relid = rel), 0);
$$;

-- 1. lock_timeout: a migration that cannot get its lock fails fast (55P03)
-- instead of waiting, and the runner retries it.
CREATE EXTENSION dblink;
SELECT dblink_connect('report', 'dbname=' || current_database());
-- A long report keeps an ACCESS SHARE lock on orders open in another session.
SELECT dblink_exec('report', 'BEGIN');
SELECT * FROM dblink('report', 'SELECT count(*) FROM orders') AS r(n bigint);

SET lock_timeout = '1s';
SELECT assert_error(
  'ALTER TABLE orders ADD COLUMN status text NOT NULL DEFAULT ''new''',
  '55P03', 'ALTER gives up after lock_timeout instead of queueing in front of traffic');

-- The report ends; the retry gets the lock at once.
SELECT dblink_exec('report', 'COMMIT');
SELECT dblink_disconnect('report');

-- 2. ADD COLUMN with a constant default is metadata-only: same relfilenode.
SELECT pg_relation_filenode('orders') AS orders_node \gset
ALTER TABLE orders ADD COLUMN status text NOT NULL DEFAULT 'new';
SELECT assert_true(pg_relation_filenode('orders') = :orders_node,
  'constant default: table not rewritten');
SELECT assert_true((SELECT count(*) FROM orders WHERE status = 'new') = 100000,
  'existing rows read the stored default');

-- A volatile default goes in three steps: nullable column, default for new
-- rows only, then a batched backfill. None of them rewrites the table.
ALTER TABLE orders ADD COLUMN created_at timestamptz;
ALTER TABLE orders ALTER COLUMN created_at SET DEFAULT clock_timestamp();
SELECT assert_true(pg_relation_filenode('orders') = :orders_node,
  'nullable column + SET DEFAULT: table not rewritten');

CREATE PROCEDURE backfill_created_at(batch int) LANGUAGE plpgsql AS $$
BEGIN
  LOOP
    UPDATE orders SET created_at = now()
    WHERE id IN (SELECT id FROM orders WHERE created_at IS NULL LIMIT batch);
    EXIT WHEN NOT FOUND;
    COMMIT; -- each batch holds its row locks only until here
  END LOOP;
END
$$;
CALL backfill_created_at(10000);
SELECT assert_true(NOT EXISTS (SELECT 1 FROM orders WHERE created_at IS NULL),
  'backfill reached every row');

-- 3. Foreign key: NOT VALID first (no scan), VALIDATE in its own transaction.
BEGIN;
SET LOCAL lock_timeout = '1s';
ALTER TABLE orders ADD CONSTRAINT orders_account_id_fkey
  FOREIGN KEY (account_id) REFERENCES accounts (id) NOT VALID;
SELECT assert_true(held_locks('orders') = 'AccessShareLock,ShareRowExclusiveLock',
  'ADD FOREIGN KEY: SHARE ROW EXCLUSIVE on the table');
SELECT assert_true(held_locks('accounts') = 'AccessShareLock,ShareRowExclusiveLock',
  'ADD FOREIGN KEY: SHARE ROW EXCLUSIVE on the referenced table too');
COMMIT;

BEGIN;
ALTER TABLE orders VALIDATE CONSTRAINT orders_account_id_fkey;
SELECT assert_true(held_locks('orders') = 'AccessShareLock,ShareUpdateExclusiveLock',
  'VALIDATE: SHARE UPDATE EXCLUSIVE, writes continue');
SELECT assert_true(held_locks('accounts') = 'AccessShareLock,RowShareLock',
  'VALIDATE: only ROW SHARE on the referenced table');
COMMIT;
SELECT assert_true((SELECT convalidated FROM pg_constraint WHERE conname = 'orders_account_id_fkey'),
  'foreign key is valid');

-- 4. NOT NULL through a validated CHECK: SET NOT NULL then skips the scan.
SET lock_timeout = '1s';
BEGIN;
ALTER TABLE orders ADD CONSTRAINT orders_account_id_not_null
  CHECK (account_id IS NOT NULL) NOT VALID;
-- Even NOT VALID, ADD CHECK takes ACCESS EXCLUSIVE: brief, but it is why
-- lock_timeout is set. Commit at once.
SELECT assert_true(held_locks('orders') = 'AccessExclusiveLock',
  'ADD CHECK NOT VALID: ACCESS EXCLUSIVE, catalog only');
COMMIT;
ALTER TABLE orders VALIDATE CONSTRAINT orders_account_id_not_null;
BEGIN;
SELECT xact_seq_scans('orders') AS scans_before \gset
ALTER TABLE orders ALTER COLUMN account_id SET NOT NULL;
SELECT assert_true(xact_seq_scans('orders') = :scans_before,
  'SET NOT NULL with a valid CHECK does not scan the table');
COMMIT;
ALTER TABLE orders DROP CONSTRAINT orders_account_id_not_null;

-- 5. PG 18+: the NOT NULL constraint itself can be added NOT VALID.
SELECT current_setting('server_version_num')::int >= 180000 AS pg18 \gset
\if :pg18
ALTER TABLE orders ADD CONSTRAINT orders_amount_not_null NOT NULL amount NOT VALID;
SELECT assert_true(NOT (SELECT convalidated FROM pg_constraint WHERE conname = 'orders_amount_not_null'),
  'PG 18: NOT NULL added NOT VALID, no scan yet');
BEGIN;
ALTER TABLE orders VALIDATE CONSTRAINT orders_amount_not_null;
SELECT assert_true(held_locks('orders') = 'ShareUpdateExclusiveLock',
  'PG 18: validating NOT NULL lets writes continue');
COMMIT;
SELECT assert_true((SELECT attnotnull FROM pg_attribute
  WHERE attrelid = 'orders'::regclass AND attname = 'amount'),
  'PG 18: after VALIDATE the column is NOT NULL');
\endif

-- 6. CREATE INDEX CONCURRENTLY cannot run in a transaction block (25001).
SELECT assert_error('CREATE INDEX CONCURRENTLY orders_created_at_idx ON orders (created_at)',
  '25001', 'CONCURRENTLY is rejected inside a transaction');
CREATE INDEX CONCURRENTLY orders_created_at_idx ON orders (created_at);

-- A failed concurrent build leaves an INVALID index. Run it in a second
-- session so this script continues, then drop and rebuild it.
SELECT dblink_exec('dbname=' || current_database(),
  'CREATE UNIQUE INDEX CONCURRENTLY accounts_email_idx ON accounts (email)', false) AS build \gset
SELECT assert_true(:'build' = 'ERROR', 'duplicate email fails the unique build');
SELECT assert_true(NOT indisvalid, 'failed concurrent build leaves an INVALID index')
FROM pg_index WHERE indexrelid = 'accounts_email_idx'::regclass;
DROP INDEX CONCURRENTLY IF EXISTS accounts_email_idx;
UPDATE accounts SET email = 'user2@example.com' WHERE id = 2;
CREATE UNIQUE INDEX CONCURRENTLY accounts_email_idx ON accounts (email);

-- 7. UNIQUE from the concurrently built index: a catalog change, no build.
ALTER TABLE accounts ADD CONSTRAINT accounts_email_key UNIQUE USING INDEX accounts_email_idx;
SELECT assert_true((SELECT contype FROM pg_constraint WHERE conname = 'accounts_email_key') = 'u',
  'unique constraint uses the prebuilt index');
SELECT assert_error('INSERT INTO accounts VALUES (5000, ''user1@example.com'')',
  '23505', 'the constraint enforces uniqueness');
RESET lock_timeout;
