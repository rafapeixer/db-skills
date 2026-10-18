---
name: mysql-online-ddl
description: Use when writing or reviewing a MySQL schema change that runs against a table serving live traffic, such as adding or dropping a column or index, widening a VARCHAR, or changing a column's type. Covers explicit ALGORITHM and LOCK clauses, INSTANT and its row-version cap, which changes are COPY, metadata locks with lock_wait_timeout and retries, INVISIBLE indexes before a drop, expand/contract, and gh-ost for changes MySQL cannot do online.
metadata:
  verified: 2026-10-18
---

# Online DDL in MySQL

## The decision

Every `ALTER TABLE` on a live InnoDB table runs with one of three algorithms. `INSTANT` changes only the data dictionary. `INPLACE` works inside the storage engine and usually lets reads and writes continue. `COPY` builds a new table row by row and blocks writes until it finishes. If you leave the clause out, MySQL picks the cheapest algorithm the operation supports and falls back to `COPY` without telling you, so a migration that looked like an instant change can rewrite a 200 GB table under a write lock. Separately, every algorithm needs an exclusive metadata lock for a moment, and with the default `lock_wait_timeout` of one year, an `ALTER` stuck behind one open transaction blocks every query on the table that arrives after it. This skill states the algorithm so MySQL refuses instead of copying, bounds every lock wait, and splits what MySQL cannot do online into steps that it can. Which tool applies the files and where it runs in a deploy is the application side; for Go services see [go-skills `db-migrations`](https://github.com/rafapeixer/go-skills/blob/main/skills/db-migrations/SKILL.md).

## The rule

1. Put an explicit algorithm on every `ALTER TABLE`: `ALGORITHM=INSTANT` with no `LOCK` clause when the operation supports it, otherwise `ALGORITHM=INPLACE, LOCK=NONE`, and treat the error as the signal to redesign the step.
2. Run every DDL with `SET SESSION lock_wait_timeout` of a few seconds, retry on error 1205 with a pause, and do not start it while a long transaction has the table open.
3. Before an instant `ADD` or `DROP COLUMN` on a table you alter often, check `INFORMATION_SCHEMA.INNODB_TABLES.TOTAL_ROW_VERSIONS` against the cap (64 on 8.4, 255 on 9.1.0+), and reset it with a planned `ALTER TABLE ... FORCE, ALGORITHM=INPLACE, LOCK=NONE` before you reach it.
4. Add and drop secondary indexes with `ALGORITHM=INPLACE, LOCK=NONE`.
5. Retire an index by making it `INVISIBLE` first, watching production for at least one release, and dropping it only then.
6. Treat a column type change, a `VARCHAR` that crosses 255 bytes and a `VARCHAR` that shrinks as `COPY`, and do them by expand/contract across releases: add the new column, dual-write, backfill in batches, switch reads, then drop the old column.
7. When a `COPY`-only change on a large table cannot be split that way, use gh-ost, which needs `ROW` binlogs with `FULL` row image and a table without foreign keys or triggers.

## Why

**Rule 1.** "Specifying an `ALGORITHM` clause requires the operation to use the specified algorithm for clauses and storage engines that support it, or fail with an error otherwise." Without it, "MySQL uses `ALGORITHM=INSTANT` for storage engines and `ALTER TABLE` clauses that support it. Otherwise, `ALGORITHM=INPLACE` is used. If `ALGORITHM=INPLACE` is not supported, `ALGORITHM=COPY` is used" ([ALTER TABLE](https://dev.mysql.com/doc/refman/8.4/en/alter-table.html)). The `LOCK` clause works the same way: `LOCK=NONE` permits concurrent reads and writes "if supported. Otherwise, an error occurs." On 8.4 and 9.7 the examples show:

| Statement | Result |
|---|---|
| `ADD COLUMN ..., ALGORITHM=INSTANT` | succeeds; `TABLE_ID` and `SPACE` unchanged, `TOTAL_ROW_VERSIONS` 0 to 1 |
| `ADD COLUMN ..., ALGORITHM=INSTANT, LOCK=NONE` | error 1221 (`HY000`): "Only `LOCK = DEFAULT` is permitted" with `INSTANT` |
| `MODIFY amount BIGINT, ALGORITHM=INSTANT` or `INPLACE, LOCK=NONE` | error 1846 (`0A000`), nothing copied |
| `MODIFY amount BIGINT` with no clause | succeeds as `COPY`: new `TABLE_ID` and `SPACE` |
| `ADD INDEX ..., ALGORITHM=INSTANT` | error 1845 (`0A000`); an index build is never instant |

"Changing the column data type is only supported with `ALGORITHM=COPY`", and `COPY` does not permit concurrent DML ([online DDL operations](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-operations.html)). The same page lists `ADD COLUMN` and `DROP COLUMN` as instant (the default in 8.4), as well as `RENAME COLUMN`, `SET DEFAULT` and `DROP DEFAULT`; an auto-increment column needs at least `ALGORITHM=INPLACE, LOCK=SHARED`. Add the clause in the migration file, so CI fails on a test database instead of production copying a table.

**Rule 2.** `lock_wait_timeout` "specifies the timeout in seconds for attempts to acquire metadata locks", and "the default is 31536000" (one year) ([server system variables](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_lock_wait_timeout)). A transaction keeps its metadata locks "until the transaction ends", so a table it has read "cannot be used in DDL statements by other sessions until the transaction ends" ([metadata locking](https://dev.mysql.com/doc/refman/8.4/en/metadata-locking.html)). Worse, "a pending exclusive metadata lock requested by an online DDL operation blocks subsequent transactions on the table", even with `LOCK=NONE` ([online DDL performance](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-performance.html)). The bad example shows it: an event holds a transaction that read `orders` for 4 seconds, an instant `ADD COLUMN` without a timeout shows as `PENDING` in `performance_schema.metadata_locks`, and a point read `WHERE id = 1` that arrives next fails with 1205 after the 1 second the test gives it. In production that read waits as long as the transaction. In the good example the `ALTER` fails with 1205 after 1 second, the same read succeeds, and a retry loop adds the column once the transaction commits. The documentation gives no figure for the timeout or retry count; a few seconds and a handful of attempts keep a stall short.

**Rule 3.** `TOTAL_ROW_VERSIONS` "is incremented each time a column is instantly added or dropped", and "the maximum number of row versions permitted is 64 (255 as of MySQL 9.1.0)" ([online DDL operations](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-operations.html)). The good example alternates instant add and drop until MySQL refuses: 64 on 8.4, 255 on 9.7, then error 4092, and the table is not rebuilt. Without the clause the same `ADD COLUMN` at the cap rebuilds the table silently (seen on both versions while writing this skill). A rebuild resets the count to 0; `FORCE` with `INPLACE, LOCK=NONE` rebuilds while allowing DML, but it still rewrites the table, so plan it.

**Rule 4.** Creating a secondary index is in place, does not rebuild the table and permits concurrent DML: "the table remains available for read and write operations while the index is being created" ([online DDL operations](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-operations.html)). The good example adds `idx_orders_customer` with `INPLACE, LOCK=NONE` and `TABLE_ID` does not change. `LOCK=NONE` costs nothing when the operation supports it and fails fast when it does not.

**Rule 5.** Invisible indexes "make it possible to test the effect of removing an index on query performance, without making a destructive change that must be undone", and "making it invisible and visible are fast, in-place operations", while "an index continues to be updated per changes to table rows" ([invisible indexes](https://dev.mysql.com/doc/refman/8.4/en/invisible-indexes.html)). The good example makes the index invisible, `EXPLAIN` stops using it and falls back to a full scan, and making it visible again is one more in-place statement. Making it visible is not instant; the examples get error 1845 for `ALGORITHM=INSTANT`, so use `INPLACE, LOCK=NONE`. A primary key cannot be invisible. The bad example drops the index directly: the lookup becomes a full scan, and the only way back is a new index build.

**Rule 6.** In-place `ALTER TABLE` "only supports increasing `VARCHAR` column size from 0 to 255 bytes, or from 256 bytes to a greater size"; shrinking "requires a table copy" ([online DDL operations](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-operations.html)). With `utf8mb4` that is 4 bytes per character: the good example widens `VARCHAR(50)` to `VARCHAR(63)` (252 bytes) in place and is refused at `VARCHAR(64)` (256 bytes); the bad example's unqualified `VARCHAR(64)` copies the table. Expand/contract replaces one `COPY` with steps that are each instant or in place, plus batched `UPDATE`s that commit separately, and the previous release keeps working at every step, which an in-place rename or retype does not give you.

**Rule 7.** gh-ost copies the table in the background and replays changes from the binary log. Its [requirements](https://github.com/github/gh-ost/blob/master/doc/requirements-and-limitations.md) say: "You will need to have one server serving Row Based Replication (RBR) format binary logs", "Right now `FULL` row image is supported", "Foreign key constraints are not supported", "Triggers are not supported", and "the two before & after tables must share a `PRIMARY KEY` or other `UNIQUE KEY`". On RDS it runs with `--assume-rbr`, without `SUPER`, and on Aurora needs `aurora_enable_repl_bin_log_filtering` set to 0 during the run ([gh-ost on RDS](https://github.com/github/gh-ost/blob/master/doc/rds.md)). This repository does not test gh-ost; check `binlog_format`, `binlog_row_image`, foreign keys and triggers before choosing it.

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
ALTER TABLE orders ADD COLUMN status TINYINT NOT NULL DEFAULT 0, ALGORITHM=INSTANT;
CALL assert_true(row_versions('orders') = 1, 'INSTANT ADD COLUMN added one row version');
CALL assert_error('ALTER TABLE orders MODIFY amount BIGINT NOT NULL, ALGORITHM=INPLACE, LOCK=NONE',
'0A000', 'type change refused as INPLACE');
```

```sql
ALTER TABLE orders ADD INDEX idx_orders_customer (customer_id), ALGORITHM=INPLACE, LOCK=NONE;
ALTER TABLE orders ALTER INDEX idx_orders_customer INVISIBLE, ALGORITHM=INPLACE, LOCK=NONE;
EXPLAIN FORMAT=JSON INTO @plan SELECT id FROM orders WHERE customer_id = 42;
CALL assert_true(NOT plan_has(@plan, 'idx_orders_customer'), 'optimizer ignores the invisible index');
```

```sql
SET SESSION lock_wait_timeout = 1;
CALL assert_error('ALTER TABLE orders ADD COLUMN shipped_at DATETIME NULL, ALGORITHM=INSTANT',
'HY000', 'ALTER gives up after 1s (error 1205) instead of queueing in front of traffic');
CALL ddl_with_retry('ALTER TABLE orders ADD COLUMN shipped_at DATETIME NULL, ALGORITHM=INSTANT', 10, @attempts);
```

The test runs on MySQL 8.4 and 9.7 and asserts: instant `ADD COLUMN` keeps `TABLE_ID` and `SPACE` and adds one row version; `INSTANT` with `LOCK=NONE` fails with `HY000`; a type change fails with `0A000` as `INSTANT` and as `INPLACE`, and nothing is copied; `VARCHAR(63)` widens in place and `VARCHAR(64)` is refused; the index build is refused as `INSTANT`, succeeds in place without a rebuild, and is used by `EXPLAIN`; the invisible index is ignored; the row-version cap is 64 on 8.4 and 255 on 9.7 with error 4092 and no rebuild; with a transaction holding the table (an event in a second session), the `ALTER` fails with 1205 after 1 second, a read still runs, and the retry succeeds after the commit.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: no ALGORITHM, so this type change silently runs as COPY: a new
-- table and tablespace, every row and index rewritten, writes blocked.
ALTER TABLE orders MODIFY amount BIGINT NOT NULL;
CALL assert_true(innodb_table_id('orders') <> @orders_id AND innodb_space('orders') <> @orders_space,
'type change copied the table into a new tablespace');
```

```sql
-- MISTAKE: the migration session keeps lock_wait_timeout at its default of
-- 31536000 seconds (one year), so it queues for the exclusive metadata lock
-- for as long as the transaction stays open.
CREATE EVENT migration ON SCHEDULE AT CURRENT_TIMESTAMP DO
ALTER TABLE orders ADD COLUMN status TINYINT NOT NULL DEFAULT 0, ALGORITHM=INSTANT;
```

```sql
CALL assert_error('SELECT COUNT(*) FROM orders WHERE id = 1',
'HY000', 'a plain point read is blocked behind the waiting ALTER (1205)');
```

The assertions describe the damage: a new `TABLE_ID` and `SPACE` after the type change and after `VARCHAR(50)` to `VARCHAR(64)`, both run as `COPY` without any error; a `PENDING` metadata lock for the `ALTER` and a point read that times out behind it while a 4-second transaction is open; and a full scan for the customer lookup after an index was dropped without the invisible step.

## Checklist

When reviewing a migration under this skill, confirm:

- [ ] Does every `ALTER TABLE` name `ALGORITHM=INSTANT` (without a `LOCK` clause) or `ALGORITHM=INPLACE, LOCK=NONE`?
- [ ] Does the session set `lock_wait_timeout` to a few seconds before the first DDL, and does the runner retry on error 1205?
- [ ] Is the migration scheduled away from long transactions on the table (reports, batch jobs, idle sessions with an open transaction)?
- [ ] For an instant `ADD` or `DROP COLUMN` on a table altered often, has `TOTAL_ROW_VERSIONS` been checked against 64 (8.4) or 255 (9.1.0+)?
- [ ] Are indexes added and dropped with `ALGORITHM=INPLACE, LOCK=NONE`?
- [ ] Was every index being dropped made `INVISIBLE` in an earlier release first?
- [ ] Is every type change, `VARCHAR` shrink or widening past 255 bytes split into expand/contract, with a batched backfill and the drop in a later release?
- [ ] If gh-ost is used, are `binlog_format=ROW` and `binlog_row_image=FULL` confirmed, and does the table have no foreign keys or triggers?

## When not to apply

- The table is new in this release or small enough that a copy takes milliseconds: a `COPY` is harmless, but still name `ALGORITHM=COPY` so the choice is visible in review, and keep `lock_wait_timeout` low.
- You have a maintenance window with traffic stopped: a direct `ALGORITHM=COPY` is simpler than expand/contract and gh-ost, and `lock_wait_timeout` still stops a forgotten session from holding the window open.
- Partitioned tables, `FULLTEXT` and `SPATIAL` indexes, and `ROW_FORMAT=COMPRESSED` tables have their own rows in the [online DDL operations](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-operations.html) tables, and instant DDL is not allowed on compressed tables or tables with a `FULLTEXT` index; look the operation up and test it with the explicit clause before relying on this skill's table.
- Aurora MySQL: this skill is tested only on community MySQL, so run the explicit clauses against a clone on your Aurora version before relying on them.
