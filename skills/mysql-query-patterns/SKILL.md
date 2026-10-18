---
name: mysql-query-patterns
description: Use when writing any MySQL pagination, infinite scroll, next page or "fetch the next N" query, or any MySQL query for an endpoint or job: lists, loading child rows, bulk inserts, upserts. Key rules: write keyset pagination OUT as created_at < ? OR (created_at = ? AND id < ?), because MySQL does not range-scan (created_at, id) < (?, ?) and reads as many rows as OFFSET; never LIMIT offset or OFFSET; one statement per page; multi-row INSERT; INSERT ... AS new ON DUPLICATE KEY UPDATE, not VALUES(); never SELECT *.
metadata:
  verified: 2026-10-18
---

# Query patterns: fewer statements, less work per statement

## The decision

Every statement an application sends costs a network round trip, a parse and execute cycle and a wait on a pooled connection, and every index entry the server reads to throw away costs CPU and buffer pool reads. The shape of the query decides both: a list endpoint can be one statement or twenty-one, page 500 can read 20 index entries or 10,000, and 1,000 rows can be one `INSERT` and one commit or 1,000 of each. None of this shows with ten rows in a demo. This skill fixes how MySQL reads and writes are shaped so a request runs the fewest statements and reads the fewest rows that give the right answer. Driver and pool specifics live in the language repositories, such as [go-skills `sql-queries-and-transactions`](https://github.com/rafapeixer/go-skills/blob/main/skills/sql-queries-and-transactions/SKILL.md); this skill is the SQL the server sees.

## The rule

1. Return a page and its small, bounded child rows in one statement: put the page's `WHERE`, `ORDER BY` and `LIMIT` in a derived table and select the children with a correlated `COALESCE((SELECT JSON_ARRAYAGG(...) ...), JSON_ARRAY())`, never one query per parent.
2. Paginate with a keyset written out as `WHERE customer_id = ? AND (created_at < ? OR (created_at = ? AND id < ?)) ORDER BY created_at DESC, id DESC LIMIT n`, on an index whose columns match that order and end in a unique column, never with `OFFSET` and never as the row constructor `(created_at, id) < (?, ?)`.
3. Write many rows with one multi-row `INSERT ... VALUES (...), (...)` (or `INSERT ... SELECT`) per batch, keep each statement under `max_allowed_packet`, and never send one `INSERT` per row in autocommit.
4. Upsert with `INSERT ... VALUES (...) AS new ON DUPLICATE KEY UPDATE col = new.col`, never with `VALUES(col)`, and only on tables with a single unique key (the primary key or one `UNIQUE`).
5. Name the columns the caller uses in every application query, never `SELECT *`.
6. Run `EXPLAIN ANALYZE` (always `FORMAT=TREE`) only in a sandbox or on a copy of the data, and use plain `EXPLAIN FORMAT=JSON` or `FORMAT=TREE`, which does not execute, against production.
7. Never use `ORDER BY RAND()` on a table that grows; pick random rows from a bounded candidate set or a precomputed random key.

## Why

**Rule 1.** A list of 20 orders that loads items per order is 21 statements; at 1 ms of round trip each, that is 20 ms of latency before any statement is slow. The bad example runs the per-order lookup from a stored procedure, and `performance_schema.events_statements_summary_by_program` counts 20 statements for one page. The good example returns the same page in one statement: the derived table cannot be merged because it has a `LIMIT`, so the correlated subquery runs once per row of the page, through the `order_items` primary key. Measured with the session `Handler_read_*` counters ([server status variables](https://dev.mysql.com/doc/refman/8.4/en/server-status-variables.html)), the whole page reads 97 index entries on 8.4 and 9.7 (20 orders, 20 lookups, 57 items) out of 100,001 orders and 300,000 items. `JSON_ARRAYAGG` "Returns `NULL` if the result contains no rows", hence the `COALESCE`, and "The order of elements in this array is undefined" ([aggregate functions](https://dev.mysql.com/doc/refman/8.4/en/aggregate-functions.html#function_json-arrayagg)), so sort in the client if order matters. Postgres evidence, not MySQL: in this project's [go-skills benchmark](https://github.com/rafapeixer/go-skills/blob/main/BENCHMARKS.md), on PostgreSQL, replacing a second query for the children with one statement per page cut CPU per request by about 9–16%.

**Rule 2.** `OFFSET` makes the server produce and discard every skipped row: the bad example's last page of a customer with 10,000 orders reads 10,000 index entries to return 20, so cost grows with depth. It is also wrong, not only slow: a row inserted between two requests shifts the window, and the bad example's next page repeats a row the client already has. The manual defines `(a, b) < (x, y)` as equivalent to `(a < x) OR ((a = x) AND (b < y))` ([comparison operators](https://dev.mysql.com/doc/refman/8.4/en/comparison-operators.html)), but range optimization of row constructors is documented only for `IN ()` ([range optimization](https://dev.mysql.com/doc/refman/8.4/en/range-optimization.html)). The examples show the consequence on 8.4 and 9.7: the row-constructor keyset is a `ref` lookup on `customer_id` filtered afterwards and reads 10,001 entries for the deep page, while the expanded `OR` is a `range` scan on all three key columns that reads 21, with no filesort and `using_index` true. The unique `id` at the end breaks ties in `created_at`; without it, rows with equal values come back "in any order" ([LIMIT optimization](https://dev.mysql.com/doc/refman/8.4/en/limit-optimization.html)) and a page boundary can skip or repeat a row. In InnoDB "each record in a secondary index contains the primary key columns for the row" ([clustered and secondary indexes](https://dev.mysql.com/doc/refman/8.4/en/innodb-index-types.html)), so `(customer_id, created_at, id)` costs nothing extra over `(customer_id, created_at)`. The cost of a keyset: no "jump to page 37" and no cheap total count.

**Rule 3.** The manual: multiple `VALUES` lists are "considerably faster (many times faster in some cases) than using separate single-row INSERT statements", and of the time to insert a row, connecting, sending and parsing weigh 3, 2 and 2 against 1 for the row itself ([optimizing INSERT](https://dev.mysql.com/doc/refman/8.4/en/insert-optimization.html)). In autocommit each statement is also a transaction, and "InnoDB must flush the log to disk at each transaction commit" ([InnoDB transaction management](https://dev.mysql.com/doc/refman/8.4/en/optimizing-innodb-transaction-management.html)). The bad example's loop runs 1,000 `INSERT` statements and 2,001 internal commits (`Handler_commit`) for 1,000 rows; the good example inserts 1,003 rows in two statements and 4 commits. Bound the batch: a packet larger than `max_allowed_packet` (64 MiB by default, 1 GiB at most) gets `ER_NET_PACKET_TOO_LARGE` and the connection is closed ([packet too large](https://dev.mysql.com/doc/refman/8.4/en/packet-too-large.html)). A few hundred to a few thousand rows per statement is far below that limit for typical rows.

**Rule 4.** "The use of VALUES() to refer to the new row and columns is deprecated, and subject to removal in a future version of MySQL" ([INSERT ... ON DUPLICATE KEY UPDATE](https://dev.mysql.com/doc/refman/8.4/en/insert-on-duplicate.html)); the bad example gets warning 1287 on every execution, and the good example's alias form gets none. The affected-rows value is 1 per inserted row, 2 per updated row and 0 per row set to its current values, so a client can tell a no-op rerun: the good example's identical rerun reports 0 and a rerun with one changed value reports 2. The same page says "you should try to avoid using an ON DUPLICATE KEY UPDATE clause on tables with multiple unique indexes": when the new row matches different rows on different keys, "only one row is updated". The bad example's upsert collides with user 1 on `id` and user 2 on `email`, reports one updated row, and the row the caller sent does not exist afterwards. With two unique keys, decide which key identifies the row, look it up by that key, and let the other one fail with a duplicate-key error.

**Rule 5.** "Using index" means "The column information is retrieved from the table using only information in the index tree without having to do an additional seek to read the actual row", which "can be used when the query uses only columns that are part of a single index" ([EXPLAIN output](https://dev.mysql.com/doc/refman/8.4/en/explain-output.html)). The good keyset page has `using_index` true; the bad example's `SELECT *` of the same page does not, so each row also costs a clustered index lookup and drags the `TEXT` column across the network. `SELECT *` also changes shape when a migration adds a column, which breaks code that maps columns by position.

**Rule 6.** "EXPLAIN ANALYZE runs a statement and produces EXPLAIN output along with timing and additional, iterator-based, information"; it works with `SELECT`, multi-table `UPDATE` and `DELETE` and `TABLE`, and "always uses the TREE output format" ([EXPLAIN](https://dev.mysql.com/doc/refman/8.4/en/explain.html)). The bad example's `EXPLAIN ANALYZE` of the deep `OFFSET` page reads the same 10,000 index entries as the query; the good example's `EXPLAIN FORMAT=JSON INTO @plan` of the same query reads none. A slow query under `EXPLAIN ANALYZE` on a production primary is still a slow query, holding its locks and buffer pool reads. Use it on a restored snapshot or a sandbox loaded with production-like volumes.

**Rule 7.** "RAND() in a WHERE clause is evaluated for every row" and "is not a constant value and cannot be used for index optimizations" ([RAND()](https://dev.mysql.com/doc/refman/8.4/en/mathematical-functions.html#function_rand)). The bad example's `ORDER BY RAND() LIMIT 1` plan is a full table scan of about 100,000 rows plus a filesort to return one row, and it grows with the table.

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
SELECT o.id, o.total_cents, o.created_at,
COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('sku', i.sku, 'qty', i.qty))
FROM order_items AS i WHERE i.order_id = o.id), JSON_ARRAY()) AS items
FROM (
    SELECT id, total_cents, created_at FROM orders
    WHERE customer_id = 3
    ORDER BY created_at DESC, id DESC
    LIMIT 20
) AS o
ORDER BY o.created_at DESC, o.id DESC;
```

```sql
SELECT id, created_at FROM orders
WHERE customer_id = 3
AND (created_at < @after_created OR (created_at = @after_created AND id < @after_id))
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

```sql
INSERT INTO order_items (order_id, sku, qty) VALUES
    (100001, 'sku-a', 2),
    (100001, 'sku-b', 1),
    (100001, 'sku-c', 5);
```

```sql
INSERT INTO stock (sku, available) VALUES ('sku-1', 10), ('sku-2', 20), ('sku-3', 31) AS new
ON DUPLICATE KEY UPDATE available = new.available;
```

On 100,001 orders and 300,000 items, the test asserts that the page returns 20 orders with their own items (and an empty array for the order that has none) and reads at most 120 index entries. The keyset page 9,980 rows deep is a `range` scan on `orders_customer_created_id` with no filesort and `using_index`, reads at most 25 entries, and a row inserted between two requests does not repeat a row on the next page. The batch inserts report 3 and 1,000 rows in a handful of commits. The upsert reports 3, then 0 for the identical rerun, then 2 for one changed value, with no warning. Plain `EXPLAIN FORMAT=JSON INTO` reads no rows.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: OFFSET reads and throws away every earlier row. The last page of
-- this customer reads 10,000 index entries to return 20; cost grows with depth.
SELECT id, created_at FROM orders WHERE customer_id = 3
ORDER BY created_at DESC, id DESC LIMIT 20 OFFSET 9980;
```

```sql
-- MISTAKE: MySQL range-optimizes row constructors only inside IN (). This
-- page is filtered after reading the index from the newest row, so the deep
-- page reads as many rows as OFFSET does.
SELECT id, created_at FROM orders
WHERE customer_id = 3 AND (created_at, id) < (@after_created, @after_id)
ORDER BY created_at DESC, id DESC LIMIT 20;
```

```sql
-- MISTAKE: the new row collides with user 1 on id and with user 2 on email.
-- MySQL updates only one of them, reports success, and the row the caller
-- asked for (id 1 with bia's email) does not exist afterwards.
INSERT INTO users (id, email, name) VALUES (1, 'bia@example.com', 'Carla') AS new
ON DUPLICATE KEY UPDATE name = new.name;
```

The assertions describe the bad outcome: the deep `OFFSET` page and the row-constructor keyset each read at least 10,000 index entries, an insert between requests makes one row appear on two `OFFSET` pages, `performance_schema` counts 20 item queries for a 20-order page and 1,000 `INSERT` statements with at least 1,000 commits for 1,000 rows, `VALUES()` raises warning 1287, the upsert on two unique keys changes one row and loses the requested one, `SELECT *` is not covered by the index, `EXPLAIN ANALYZE` reads the 10,000 rows it explains, and `ORDER BY RAND()` scans the whole table and sorts it. If any of these stops happening, the example fails.

## Checklist

When reviewing SQL under this skill, confirm:

- [ ] No code path runs a query per row of a result; small, bounded children come back with their page in one statement.
- [ ] The page's `LIMIT` sits in a derived table before the child subquery, so children are read only for rows on the page.
- [ ] No list query uses `OFFSET` beyond a small, bounded admin table.
- [ ] Keyset conditions are written as `a < ? OR (a = ? AND id < ?)`, not as a row constructor, and the plan shows `range` on the keyset index with no filesort.
- [ ] Writes of many rows use one multi-row `INSERT` per batch, sized well under `max_allowed_packet`, not a loop of single-row statements in autocommit.
- [ ] Upserts use `AS new ... new.col`; no `VALUES(col)` in `ON DUPLICATE KEY UPDATE`.
- [ ] No `ON DUPLICATE KEY UPDATE` targets a table with more than one unique key.
- [ ] Application queries name their columns; no `SELECT *` outside ad hoc sessions.
- [ ] `EXPLAIN ANALYZE` appears only in sandbox runbooks, not against a production primary.
- [ ] No `ORDER BY RAND()` on a table that grows.

## When not to apply

- **Large or unbounded child sets.** A customer's orders or a post's comments grow without limit; one JSON array per parent grows with them. Load them with their own keyset-paged query, or with a second `WHERE parent_id IN (...)` query for the page's ids, kept to hundreds of values so the range optimizer stays within `range_optimizer_max_mem_size` ([range optimization](https://dev.mysql.com/doc/refman/8.4/en/range-optimization.html)).
- **Small, fixed admin tables.** A back-office table of a few thousand rows that needs page numbers can use `OFFSET`; switch to a keyset before the table or the depth grows.
- **Bulk loads.** For millions of rows from a file, `LOAD DATA` ("usually 20 times faster than using INSERT statements", [optimizing INSERT](https://dev.mysql.com/doc/refman/8.4/en/insert-optimization.html)) into a staging table and one `INSERT ... SELECT` replace batches of `VALUES` lists; that is an operations job, not a request path.
- **Tables with two natural keys.** When the table must keep two unique keys, do not upsert: `INSERT`, catch the duplicate-key error (SQLSTATE `23000`), and resolve it by the one key that identifies the row.
- **Ad hoc and exploratory sessions.** `SELECT *` and `ORDER BY RAND() LIMIT 10` on a small sample in a console are fine; the rules are for queries that ship in application code, views and procedures.
