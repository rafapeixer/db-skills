---
name: pg-online-migrations
description: Use when writing any PostgreSQL migration for a table in production: adding a column, index, constraint, NOT NULL or foreign key, renaming or changing a type. Key rules: SET lock_timeout and retry on 55P03; CREATE INDEX CONCURRENTLY outside a transaction; ADD FOREIGN KEY/CHECK ... NOT VALID, then VALIDATE CONSTRAINT; NOT NULL via a validated CHECK, or on PG 18+ ADD CONSTRAINT ... NOT NULL col NOT VALID then VALIDATE; constant defaults only; expand/contract for renames and type changes.
metadata:
  verified: 2026-10-19
---

# Online schema migrations in PostgreSQL

## The decision

Every schema change on a live table has to decide which lock it takes, for how long, and what happens to the queries that arrive while it waits. Most `ALTER TABLE` forms take `ACCESS EXCLUSIVE`, which conflicts with every lock, including the `ACCESS SHARE` of a plain `SELECT`. The statement itself is usually fast. The outage comes from two things: a statement that rewrites or scans the whole table while it holds that lock, and a statement that waits for the lock behind a long transaction while every new query queues behind it. This skill picks the form of each change that touches only the catalog or holds a lock that lets reads and writes continue, and bounds every lock wait. Which tool applies the files and where it runs in a deploy is the application side; for Go services see [go-skills `db-migrations`](https://github.com/rafapeixer/go-skills/blob/main/skills/db-migrations/SKILL.md).

## The rule

1. Start every migration session with `SET lock_timeout` (a few seconds), retry the step on SQLSTATE `55P03` with backoff, and commit each heavy-lock step on its own.
2. Before running an `ALTER TABLE`, look up the lock it takes: assume `ACCESS EXCLUSIVE` unless the documentation names a weaker one, and allow it only for statements that change the catalog without scanning or rewriting.
3. Add a column nullable or with a constant default; for a volatile default, a stored generated column, an identity column or a type that is not binary coercible, add a new nullable column, `SET DEFAULT` separately and backfill in batches.
4. Add foreign keys and `CHECK` constraints with `NOT VALID`, then run `VALIDATE CONSTRAINT` in a separate transaction.
5. Make a column `NOT NULL` through a validated `CHECK (col IS NOT NULL)`, then `SET NOT NULL` and drop the check; on PG 18+ use `ADD CONSTRAINT ... NOT NULL col NOT VALID` and `VALIDATE CONSTRAINT`.
6. Build indexes on existing tables with `CREATE INDEX CONCURRENTLY` outside any transaction block, and recover a failed build by `DROP INDEX CONCURRENTLY IF EXISTS` and building again, never with `IF NOT EXISTS`.
7. Add `UNIQUE` and `PRIMARY KEY` constraints with `ADD CONSTRAINT ... USING INDEX` over a unique index built concurrently.
8. Rename, retype or drop a column in use by expand/contract across releases: add the new shape, dual-write, backfill, switch reads, then drop the old shape in a later release.

## Why

**Rule 1.** `lock_timeout` defaults to `0`, which disables the timeout, and "a transaction seeking either a table-level or row-level lock will wait indefinitely for conflicting locks to be released" ([explicit locking](https://www.postgresql.org/docs/18/explicit-locking.html), [lock_timeout](https://www.postgresql.org/docs/18/runtime-config-client.html#GUC-LOCK-TIMEOUT)). The bad example shows the cost: a report holds `ACCESS SHARE` on `orders`, an `ADD COLUMN` without a timeout waits for `ACCESS EXCLUSIVE`, and a plain `SELECT ... WHERE id = 1` that arrives next is blocked behind the waiting `ALTER` (it fails with `55P03` after the 500 ms the test allows it). In production that read would hang for as long as the report runs. With `lock_timeout = '1s'` the good example's `ALTER` fails with `55P03`, traffic keeps flowing, and the retry after the report commits succeeds at once. The timeout applies "separately to each lock acquisition attempt", and a `lock_timeout` equal to or above a nonzero `statement_timeout` is pointless because the statement timeout fires first. Locks are "held until the end of the transaction", so a transaction that chains several `ACCESS EXCLUSIVE` steps keeps the first one for as long as the last one takes; commit each step. The exact timeout and retry count are your call; the documentation gives no figure.

**Rule 2.** "An ACCESS EXCLUSIVE lock is acquired unless explicitly noted" ([ALTER TABLE 18](https://www.postgresql.org/docs/18/sql-altertable.html)), and "only an ACCESS EXCLUSIVE lock blocks a SELECT" ([explicit locking](https://www.postgresql.org/docs/18/explicit-locking.html)). With several subcommands in one statement, "the lock acquired will be the strictest one required by any subcommand". The examples record what `pg_locks` shows inside the transaction on PG 15 and 18:

| Statement | Lock on the table | Blocks |
|---|---|---|
| `ADD COLUMN`, `ADD CHECK ... NOT VALID`, `SET NOT NULL`, `ADD CONSTRAINT ... USING INDEX`, `DROP INDEX` | `ACCESS EXCLUSIVE` | reads and writes |
| `ADD CONSTRAINT ... UNIQUE (col)` without `USING INDEX` | `ACCESS EXCLUSIVE`, plus `SHARE` for the index it builds | reads and writes, for the whole build |
| `ADD FOREIGN KEY` (with or without `NOT VALID`) | `SHARE ROW EXCLUSIVE` on both tables | writes on both tables |
| `CREATE INDEX` | `SHARE` | writes |
| `VALIDATE CONSTRAINT`, `CREATE INDEX CONCURRENTLY` | `SHARE UPDATE EXCLUSIVE` | other DDL and `VACUUM`, not reads or writes |

`ACCESS EXCLUSIVE` is acceptable only when the statement finishes in milliseconds because it touches only the catalog, and `lock_timeout` bounds the wait to get it.

**Rule 3.** "When a column is added with ADD COLUMN and a non-volatile DEFAULT is specified, the default value is evaluated at the time of the statement and the result stored in the table's metadata" with no rewrite. "Adding a column with a volatile DEFAULT (e.g., clock_timestamp()), a stored generated column, an identity column, or a column with a domain data type that has constraints will cause the entire table and its indexes to be rewritten" ([ALTER TABLE 18](https://www.postgresql.org/docs/18/sql-altertable.html)). The good example adds `status text NOT NULL DEFAULT 'new'` to 100,000 rows and `pg_relation_filenode('orders')` does not change; the bad example's `DEFAULT clock_timestamp()` gives the table and `orders_pkey` new filenodes, which is a full copy under `ACCESS EXCLUSIVE`. A type change "will normally cause the entire table and its indexes to be rewritten" unless the old type is binary coercible to the new one; the bad example's `int` to `bigint` rewrites again. Rebuilds "temporarily require as much as double the disk space". `NOT NULL` with no default at all is worse than a rewrite: the bad example's `ADD COLUMN sku text NOT NULL` fails with `23502` on a table that has rows, because nothing fills them, so the migration aborts. `SET DEFAULT` affects only rows inserted afterwards, so the backfill fills old rows in batches of 10,000, each committed by the procedure, so no transaction holds row locks on the whole table.

**Rule 4.** `NOT VALID` skips the scan of existing rows but enforces the constraint on new writes. `VALIDATE CONSTRAINT` "acquires a SHARE UPDATE EXCLUSIVE lock" on the table and, for a foreign key, a `ROW SHARE` lock on the referenced table, so it "does not need to lock out concurrent updates". `ADD FOREIGN KEY` takes `SHARE ROW EXCLUSIVE` on the table and on the referenced table ([ALTER TABLE 18](https://www.postgresql.org/docs/18/sql-altertable.html)). In one step, the bad example's validation scan of `orders` runs while that lock is held, and an `INSERT INTO accounts` from another session fails with `55P03`: a signup is blocked by a migration on `orders`. The good example holds the same lock only for the catalog change, then validates under the weaker locks.

**Rule 5.** `SET NOT NULL` scans the whole table under `ACCESS EXCLUSIVE`, "however, if a valid CHECK constraint exists (and is not dropped in the same command) which proves no NULL can exist, then the table scan is skipped" ([ALTER TABLE 15](https://www.postgresql.org/docs/15/sql-altertable.html)). The examples count sequential scans of `orders` inside the transaction: one for the bare `SET NOT NULL` in the bad example, zero after the validated check in the good one. Drop the check in a later statement, not in the same one. PG 18 allows `NOT VALID` on not-null constraints ([PG 18 release notes](https://www.postgresql.org/docs/18/release-18.html)); the good example adds one, sees `convalidated = false`, and validates it under `SHARE UPDATE EXCLUSIVE`, after which `pg_attribute.attnotnull` is true.

**Rule 6.** A plain `CREATE INDEX` "locks out writes (but not reads) on the table until it's done"; `CONCURRENTLY` builds "without taking any locks that prevent concurrent inserts, updates, or deletes", but "cannot" run "within a transaction block" ([CREATE INDEX 18](https://www.postgresql.org/docs/18/sql-createindex.html)). The good example shows both: the build fails with `25001` when run inside a function, and succeeds as a top-level autocommit statement, which is how the migration step must run. A concurrent build that fails (a deadlock, a duplicate in a unique index, a timeout) leaves an index marked `INVALID` that queries ignore but writes still maintain; the documented recovery is to drop it and build again, or `REINDEX INDEX CONCURRENTLY`. The bad example retries with `IF NOT EXISTS`, which sees the invalid index by name and skips the build, so `indisvalid` stays false. Dropping is the same story: "a normal `DROP INDEX` acquires an exclusive lock on the table, blocking other accesses until the index drop can be completed", while `DROP INDEX CONCURRENTLY` "waits until conflicting transactions have completed" ([DROP INDEX 18](https://www.postgresql.org/docs/18/sql-dropindex.html)). The bad example's plain `DROP INDEX` holds `ACCESS EXCLUSIVE` on `orders`, and a plain `SELECT` from another session fails with `55P03` behind it.

**Rule 7.** `ADD CONSTRAINT ... USING INDEX` turns an existing unique index into a `UNIQUE` or `PRIMARY KEY` constraint and "is a fast operation", which is the documented way to add one "without blocking table updates for a long time". The exception: for a `PRIMARY KEY` whose columns are not already `NOT NULL`, it runs `SET NOT NULL`, which "requires a full table scan", so do rule 5 first. The index must be a plain b-tree with default sort order, not partial and without expressions, and the form does not work on partitioned tables ([ALTER TABLE 18](https://www.postgresql.org/docs/18/sql-altertable.html)). The documented primary-key swap is `CREATE UNIQUE INDEX CONCURRENTLY`, then one `ALTER TABLE` that drops the old key and adds the new one `USING INDEX`. Without the prebuilt index, `ADD CONSTRAINT ... UNIQUE (email)` in the bad example scans `accounts` and builds the index itself while it holds `ACCESS EXCLUSIVE` (and the build's `SHARE`) on the table; an `INSERT` from another session fails with `55P03`.

**Rule 8.** The previous release keeps serving while and after the migration runs. A one-step `RENAME COLUMN` or `DROP COLUMN` breaks every query of that code when it commits, and a retype in place rewrites the table (rule 3). Expand/contract makes every step one of the safe forms above, at the cost of two or three releases for one logical change.

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
SET lock_timeout = '1s';
SELECT assert_error(
'ALTER TABLE orders ADD COLUMN status text NOT NULL DEFAULT ''new''',
'55P03', 'ALTER gives up after lock_timeout instead of queueing in front of traffic');
```

```sql
BEGIN;
SET LOCAL lock_timeout = '1s';
ALTER TABLE orders ADD CONSTRAINT orders_account_id_fkey
FOREIGN KEY (account_id) REFERENCES accounts (id) NOT VALID;
COMMIT;

BEGIN;
ALTER TABLE orders VALIDATE CONSTRAINT orders_account_id_fkey;
SELECT assert_true(held_locks('orders') = 'AccessShareLock,ShareUpdateExclusiveLock',
'VALIDATE: SHARE UPDATE EXCLUSIVE, writes continue');
COMMIT;
```

```sql
DROP INDEX CONCURRENTLY IF EXISTS accounts_email_idx;
UPDATE accounts SET email = 'user2@example.com' WHERE id = 2;
CREATE UNIQUE INDEX CONCURRENTLY accounts_email_idx ON accounts (email);
ALTER TABLE accounts ADD CONSTRAINT accounts_email_key UNIQUE USING INDEX accounts_email_idx;
```

The test runs on PG 15 and 18 and asserts: `ALTER` fails with `55P03` while another session (through `dblink`) holds a lock, then succeeds after it commits; a constant default and a nullable column plus `SET DEFAULT` keep the table's filenode; the foreign key holds `SHARE ROW EXCLUSIVE` on both tables only for the catalog change, and `VALIDATE` holds `SHARE UPDATE EXCLUSIVE` and `ROW SHARE`; `SET NOT NULL` after a validated check scans nothing; on PG 18 the `NOT NULL ... NOT VALID` path ends with `attnotnull`; `CREATE INDEX CONCURRENTLY` fails with `25001` inside a transaction block; a failed unique build leaves `indisvalid = false` and is rebuilt; and the `USING INDEX` constraint rejects a duplicate with `23505`.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: lock_timeout is 0 (wait forever), so the ALTER queues for its
-- ACCESS EXCLUSIVE lock for as long as the report runs.
SELECT dblink_send_query('migration', 'ALTER TABLE orders ADD COLUMN note text');
```

```sql
-- MISTAKE: clock_timestamp() is volatile, so every row gets its own value:
-- full rewrite of the table and its indexes under ACCESS EXCLUSIVE.
ALTER TABLE orders ADD COLUMN created_at timestamptz NOT NULL DEFAULT clock_timestamp();
SELECT assert_true(pg_relation_filenode('orders') <> :orders_node,
'volatile default rewrote the table');
```

```sql
-- MISTAKE: no NOT VALID, so the full validation scan runs while
-- SHARE ROW EXCLUSIVE is held on orders and on accounts.
ALTER TABLE orders ADD CONSTRAINT orders_account_id_fkey
FOREIGN KEY (account_id) REFERENCES accounts (id);
```

```sql
-- MISTAKE: no CREATE UNIQUE INDEX CONCURRENTLY first, so ADD CONSTRAINT
-- scans the table and builds the index itself while reads and writes wait.
ALTER TABLE accounts ADD CONSTRAINT accounts_email_key UNIQUE (email);
```

```sql
-- MISTAKE: no CONCURRENTLY, so the drop waits for every running query on
-- orders and, from then until commit, every new query on orders waits.
DROP INDEX orders_created_at_idx;
```

The assertions describe the damage: a plain `SELECT` blocked behind the waiting `ALTER`; new filenodes for the table and its primary key after the volatile default and after `int` to `bigint`; a sequential scan inside the one-step foreign key while an `INSERT` on the referenced table fails with `55P03`; a scan under `ACCESS EXCLUSIVE` for the bare `SET NOT NULL`; `SHARE` for a plain `CREATE INDEX`; an index still `INVALID` after the `IF NOT EXISTS` retry; `23502` for `ADD COLUMN ... NOT NULL` with no default on a table with rows; a scan and `ACCESS EXCLUSIVE` plus `SHARE` while `ADD CONSTRAINT ... UNIQUE` builds its own index, with an `INSERT` from another session failing with `55P03`; and `ACCESS EXCLUSIVE` on the table for a plain `DROP INDEX`, with a `SELECT` from another session failing with `55P03`.

## Checklist

When reviewing a migration under this skill, confirm:

- [ ] Does the session set `lock_timeout` before the first DDL, and does the runner retry on `55P03`?
- [ ] Does each statement that takes `ACCESS EXCLUSIVE` only change the catalog, with no rewrite or full scan, and commit right after?
- [ ] Is every new column nullable or given a constant default, with volatile defaults, identity and stored generated columns done as a new column plus a batched backfill?
- [ ] Is every new foreign key and `CHECK` added `NOT VALID` and validated in a separate transaction?
- [ ] Is `SET NOT NULL` preceded by a validated `CHECK (col IS NOT NULL)` (or, on PG 18+, a `NOT NULL ... NOT VALID` constraint that is then validated)?
- [ ] Is every index on an existing table built `CONCURRENTLY`, outside a transaction block, with `DROP INDEX CONCURRENTLY IF EXISTS` before it instead of `IF NOT EXISTS`?
- [ ] Are new `UNIQUE` and `PRIMARY KEY` constraints added `USING INDEX` over a concurrently built index, with the key columns already `NOT NULL`?
- [ ] Is a rename, retype or drop of a column in use split across releases, with the drop in a later one?
- [ ] Does the backfill run in batches that commit separately, outside the DDL transaction?

## When not to apply

- The table is new in this release or empty, and nothing reads it yet: a plain `CREATE INDEX`, a one-step foreign key or a rewrite costs nothing, and the multi-step forms only add files.
- You have an agreed maintenance window with traffic stopped: one transaction with all the steps is simpler and rolls back as a unit; still set `lock_timeout` so a forgotten session does not hold the window open.
- Partitioned tables follow different rules: `USING INDEX` is not available, `CREATE INDEX CONCURRENTLY` is not supported on the parent, and `NOT VALID` foreign keys on partitioned tables need PG 18+. Build the index concurrently on each partition, then create the parent index without `CONCURRENTLY`, which is then "a metadata only operation" ([CREATE INDEX 18](https://www.postgresql.org/docs/18/sql-createindex.html)).
- A small lookup table that fits in a few pages: a rewrite takes milliseconds, so `ALTER COLUMN TYPE` in place with `lock_timeout` set is acceptable; the rule exists for tables where a rewrite or scan takes seconds or more.
