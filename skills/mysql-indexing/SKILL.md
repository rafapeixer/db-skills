---
name: mysql-indexing
description: Use when adding, reviewing or removing MySQL (InnoDB) indexes, writing a migration that creates one, or EXPLAIN shows type ALL, Using filesort or index_merge you did not expect. Covers composite column order and the leftmost-prefix rule, covering indexes and the implicit primary key, functional and descending indexes, predicates that disable an index (functions, implicit type conversion), and dropping indexes safely with INVISIBLE and the sys schema.
metadata:
  verified: 2026-10-18
---

# Indexing (MySQL)

## The decision

Every InnoDB secondary index is a second B-tree that every `INSERT`, every `DELETE` and every `UPDATE` of its columns must maintain. The decision is which indexes to create for the queries you actually run, in what column order, and which to drop. Get it wrong and the costs are concrete: a composite index in the wrong order is still used but examines 99,000 rows to return 11; an index on a `VARCHAR` does nothing when the application binds the value as a number; `DATE(created_at) = ?` scans 200,000 rows next to a perfectly good index on `created_at`; two single-column indexes get intersected instead of one seek; and a redundant index costs space and write time without ever being read. This skill fixes how you pick an index for a query and how you remove one without an outage.

## The rule

1. Order composite keys as equality columns first, then the one range or `ORDER BY` column; a query that does not filter on a leftmost prefix of the index cannot seek it.
2. Never list the primary key in a secondary index to make it covering: InnoDB already stores the primary key in every secondary index record, so add only the other columns the hot query reads.
3. Keep indexed columns bare in `WHERE`: no function around them, and compare them with a value of the same type (`ref_code = '4242'`, not `ref_code = 4242`); rewrite `DATE(col) = d` as `col >= d AND col < d + 1 day`.
4. When the expression cannot be rewritten (a JSON attribute, a computed value), create a functional index (MySQL 8.0.13+) and repeat the exact same expression in the query.
5. When `ORDER BY` mixes directions, declare the index with the same mix (`priority, created_at DESC`) so it is read in order without a filesort.
6. Treat `type: index_merge` on an `AND` of equalities as a missing composite index: replace the single-column indexes with one index on all the equality columns.
7. Drop indexes that `sys.schema_redundant_indexes` reports and those `sys.schema_unused_indexes` lists after a full business cycle, but make each one `INVISIBLE` first and drop it only when nothing regressed on the primary and every replica.
8. On a live table, create and drop indexes with online DDL as described in [mysql-online-ddl](../mysql-online-ddl/SKILL.md).

## Why

**Rule 1.** "Any leftmost prefix of the index can be used by the optimizer to look up rows. For example, if you have a three-column index on `(col1, col2, col3)`, you have indexed search capabilities on `(col1)`, `(col1, col2)`, and `(col1, col2, col3)`", and "MySQL cannot use the index to perform lookups if the columns do not form a leftmost prefix of the index" ([Multiple-Column Indexes](https://dev.mysql.com/doc/refman/8.4/en/multiple-column-indexes.html)). With `(customer_id, created_at)`, the query `WHERE customer_id = 42 AND created_at >= '2026-03-01' ORDER BY created_at LIMIT 20` is a range scan that examines 11 rows in the good example. With `(created_at, customer_id)` the same query still uses the index, but the seek stops at the range column and the plan examines about 99,000 rows (every order since March) in the bad example. Putting the sort column right after the equality columns also removes the sort: with `WHERE key_part1 = constant ORDER BY key_part2`, "all rows accessed through the index are in `key_part2` order, and an index on `(key_part1, key_part2)` avoids sorting" ([ORDER BY Optimization](https://dev.mysql.com/doc/refman/8.4/en/order-by-optimization.html)).

**Rule 2.** "In `InnoDB`, each record in a secondary index contains the primary key columns for the row, as well as the columns specified for the secondary index" ([Clustered and Secondary Indexes](https://dev.mysql.com/doc/refman/8.4/en/innodb-index-types.html)). So `SELECT id, created_at ... WHERE customer_id = ?` is covered by `(customer_id, created_at)` alone: the good example's plan shows `using_index: true`, meaning no lookup into the clustered index per row. "If a query uses from a table only columns that are included in some index, the selected values can be retrieved from the index tree for greater speed" ([How MySQL Uses Indexes](https://dev.mysql.com/doc/refman/8.4/en/mysql-indexes.html)). The same fact has a cost: "If the primary key is long, the secondary indexes use more space, so it is advantageous to have a short primary key."

**Rule 3.** "For comparisons of a string column with a number, MySQL cannot use an index on the column to look up the value quickly ... there are many different strings that may convert to the value `1`, such as `'1'`, `' 1'`, or `'1a'`" ([Type Conversion in Expression Evaluation](https://dev.mysql.com/doc/refman/8.4/en/type-conversion.html)). In the bad example, `ref_code = 4242` lists `orders_ref_code_idx` in `possible_keys` and still reads all 200,000 rows (`type: ALL`); `ref_code = '4242'` is a `ref` lookup on one row. This usually comes from the driver: an integer bound to a string column. Different character sets do the same: "comparing a `utf8mb4` column with a `latin1` column precludes use of an index" ([How MySQL Uses Indexes](https://dev.mysql.com/doc/refman/8.4/en/mysql-indexes.html)). A function around the column hides it from the index too: `DATE(created_at) = '2026-03-01'` is a full table scan in the bad example, while the half-open range on the bare column is a `range` scan of 1,440 rows in the good one.

**Rule 4.** "MySQL 8.0.13 and higher supports functional key parts that index expression values rather than column or column prefix values" ([CREATE INDEX](https://dev.mysql.com/doc/refman/8.0/en/create-index.html)). They "are implemented as hidden virtual generated columns": the column takes no storage, the index does. The query has to match: for `SUBSTRING(col1, 1, 10)` "the `WHERE` clause must contain `SUBSTRING()` with the same arguments", and `->>` returns `LONGTEXT`, which cannot be indexed without a prefix, so a JSON attribute needs a `CAST(... AS CHAR(n))` in both the index and the query ([CREATE INDEX: Functional Key Parts](https://dev.mysql.com/doc/refman/8.4/en/create-index.html#create-index-functional-key-parts)). The good example's tracking-number lookup is a `ref` on `orders_tracking_idx`. Prefer the rewrite of rule 3 when one exists: a functional index is one more index to maintain on every write.

**Rule 5.** "Descending indexes also make it possible for the optimizer to use multiple-column indexes when the most efficient scan order mixes ascending order for some columns and descending order for others" ([Descending Indexes](https://dev.mysql.com/doc/refman/8.4/en/descending-indexes.html)); the index "must have the same homogeneity, but need not have the same actual direction" ([ORDER BY Optimization](https://dev.mysql.com/doc/refman/8.4/en/order-by-optimization.html)). In the bad example, `(queue_id, priority, created_at)` serves `WHERE queue_id = 7 ORDER BY priority ASC, created_at DESC` with `using_filesort: true`; with `created_at DESC` in the index the good example has no filesort. Descending key parts are InnoDB B-tree only, disable change buffering for that index, and are not used for `MIN()`/`MAX()` without `GROUP BY`.

**Rule 6.** "If a multiple-column index exists on `col1` and `col2`, the appropriate rows can be fetched directly. If separate single-column indexes exist on `col1` and `col2`, the optimizer attempts to use the Index Merge optimization ... or attempts to find the most restrictive index" ([Multiple-Column Indexes](https://dev.mysql.com/doc/refman/8.4/en/multiple-column-indexes.html)). Index merge "appears as `index_merge` in the `type` column" ([Index Merge Optimization](https://dev.mysql.com/doc/refman/8.4/en/index-merge-optimization.html)). In the bad example, `queue_id = 7 AND agent_id = 3` intersects `tickets_queue_idx` (4,000 entries) and `tickets_agent_idx` (5,000 entries) to return 100 rows; the composite `(queue_id, agent_id)` in the good example is one `ref` seek straight to those 100. An `index_merge` union for an `OR` across different columns is a different case: no single composite index serves it.

**Rule 7.** `sys.schema_redundant_indexes` "displays indexes that duplicate other indexes or are made redundant by them" and returns a `sql_drop_index` statement for each ([schema_redundant_indexes](https://dev.mysql.com/doc/refman/8.4/en/sys-schema-redundant-indexes.html)); in the bad example it reports `orders_created_idx` as made redundant by `orders_created_customer_idx`. `sys.schema_unused_indexes` lists indexes "for which there are no events", and "is most useful when the server has been up and processing long enough that its workload is representative" ([schema_unused_indexes](https://dev.mysql.com/doc/refman/8.4/en/sys-schema-unused-indexes.html)): it starts empty after every restart and covers only the server you query, so a replica that serves reports can use an index the primary never touches. That is why you hide before you drop. An invisible index is "not used by the optimizer", yet "an index continues to be updated per changes to table rows, and a unique index prevents insertion of duplicates"; "Dropping and re-adding an index can be expensive for a large table, whereas making it invisible and visible are fast, in-place operations" ([Invisible Indexes](https://dev.mysql.com/doc/refman/8.4/en/invisible-indexes.html)). A primary key, explicit or implicit, cannot be made invisible. One session can still test the hidden index with `optimizer_switch` `use_invisible_indexes=on`, as the good example does.

**Rule 8.** Creating a secondary index is in place, does not rebuild the table and permits concurrent DML; dropping one only modifies metadata ([Online DDL Operations](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-operations.html)). Neither is instant, and the build still waits on transactions holding the table; [mysql-online-ddl](../mysql-online-ddl/SKILL.md) covers the `ALGORITHM`/`LOCK` clauses, the metadata lock and replica lag.

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
CREATE INDEX orders_customer_created_idx ON orders (customer_id, created_at);
CREATE INDEX orders_tracking_idx ON orders ((CAST(payload->>'$.tracking' AS CHAR(32))));
CREATE INDEX tickets_queue_agent_idx ON tickets (queue_id, agent_id);
CREATE INDEX tickets_queue_priority_created_idx ON tickets (queue_id, priority, created_at DESC);

EXPLAIN FORMAT=JSON INTO @p SELECT id, created_at FROM orders WHERE customer_id = 42 AND created_at >= '2026-03-01' ORDER BY created_at LIMIT 20;
CALL assert_true(JSON_CONTAINS(JSON_EXTRACT(@p, '$**.using_index'), 'true'), 'covering: id comes from the secondary index');
CALL assert_true(NOT JSON_CONTAINS(COALESCE(JSON_EXTRACT(@p, '$**.using_filesort'), JSON_ARRAY()), 'true'), 'index order satisfies ORDER BY, no filesort');

EXPLAIN FORMAT=JSON INTO @p SELECT * FROM orders WHERE created_at >= '2026-03-01' AND created_at < '2026-03-02';
ALTER TABLE orders ALTER INDEX orders_status_idx INVISIBLE;
CALL assert_true(NOT plan_has(@p, 'orders_status_idx'), 'invisible index is ignored by the optimizer');
```

With 200k orders and 200k tickets, the test asserts on MySQL 8.4 and 9.7 that:

- The customer query uses `orders_customer_created_idx`, is covered (`using_index: true`, the `id` comes from the index), has no filesort and examines fewer than 50 rows.
- `ref_code = '4242'` is a `ref` lookup, and the day query written as a range on bare `created_at` is a `range` scan.
- The JSON tracking-number lookup uses the functional index.
- `queue_id = ? AND agent_id = ?` is one `ref` on the composite index, with no `index_merge`.
- `ORDER BY priority ASC, created_at DESC` reads the descending index with no filesort.
- After `ALTER INDEX ... INVISIBLE` the optimizer stops using `orders_status_idx`, the index still exists, and a `use_invisible_indexes=on` hint sees it again.
- `sys.schema_redundant_indexes` reports nothing for the schema.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: range column first. The seek stops at created_at, so one customer's 11 rows cost a scan of every order since March.
CREATE INDEX orders_created_customer_idx ON orders (created_at, customer_id);

-- MISTAKE: a left prefix of the index above. Every insert pays for both; sys.schema_redundant_indexes flags it.
CREATE INDEX orders_created_idx ON orders (created_at);

-- MISTAKE: VARCHAR column compared with a number. MySQL converts every ref_code to a number, so the index is useless.
EXPLAIN FORMAT=JSON INTO @p SELECT * FROM orders WHERE ref_code = 4242;

-- MISTAKE: function around the indexed column. DATE(created_at) hides created_at from the index.
EXPLAIN FORMAT=JSON INTO @p SELECT * FROM orders WHERE DATE(created_at) = '2026-03-01';

-- MISTAKE: two single-column indexes for an AND of two equalities. The optimizer intersects them (index_merge) instead of one seek.
CREATE INDEX tickets_queue_idx ON tickets (queue_id);
CREATE INDEX tickets_agent_idx ON tickets (agent_id);
```

The assertions describe the damage: the customer query examines more than 50,000 rows (about 99,000 on 8.4, against 11); `ref_code = 4242` and `DATE(created_at) = ?` are `type: ALL` full scans even though the index is in `possible_keys`; the ticket lookup is an `index_merge`; the all-ascending index leaves `using_filesort: true` on the mixed `ORDER BY`; and `sys.schema_redundant_indexes` reports `orders_created_idx` as redundant with `orders_created_customer_idx`. The queries still return the right rows, which is why these mistakes survive code review.

## Checklist

When reviewing schema or SQL under this skill, confirm:

- [ ] Each new index names the query it serves, and `EXPLAIN` of that query shows it in `key` with `type` `ref`, `range` or `eq_ref`, not `ALL`.
- [ ] Composite keys list equality columns first, then the single range or `ORDER BY` column, and every query on the index filters on a leftmost prefix.
- [ ] No secondary index lists the primary key columns just to cover a query.
- [ ] No `WHERE` clause wraps an indexed column in a function, and every bound value has the column's type (strings to strings, no integer against `VARCHAR`).
- [ ] Each functional index (8.0.13+) is matched by the identical expression in the query, including the `CAST`.
- [ ] Each `ORDER BY` that mixes `ASC` and `DESC` on a hot path has an index with the same mix, and its plan shows no `Using filesort`.
- [ ] No hot query plan shows `index_merge` over an `AND`; if it does, a composite index replaces the single-column ones.
- [ ] `sys.schema_redundant_indexes` is empty for the application schema, or each row is explained (for example, a unique index enforcing a constraint).
- [ ] Every index proposed for removal has been `INVISIBLE` for a full business cycle, with no regression on the primary or any replica, before the `DROP INDEX`.
- [ ] Index changes on existing tables follow [mysql-online-ddl](../mysql-online-ddl/SKILL.md).

## When not to apply

- Small tables (a few thousand rows): a full scan is as fast as any index, so add only the primary key and the indexes constraints need.
- `OR` across different columns: an `index_merge` union may be the best plan available; rule 6 is about `AND`. Consider rewriting the query as a `UNION` of two indexed queries if the merge is slow.
- Unique indexes that `sys.schema_unused_indexes` lists: nobody reads them, but they enforce a constraint on every write. Keep them.
- Full-text search (`MATCH ... AGAINST`) and spatial queries need `FULLTEXT` and `SPATIAL` indexes; the B-tree column order rules here do not apply to them, and neither do descending or functional key parts.
