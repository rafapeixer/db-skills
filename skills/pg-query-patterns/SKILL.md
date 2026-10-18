---
name: pg-query-patterns
description: Use when writing or reviewing PostgreSQL queries that load a page of rows with their children, paginate a list, insert or update many rows, upsert, read back what was just written, or select columns. Covers one statement per page with LEFT JOIN LATERAL and array_agg or json_agg instead of N+1 or a second query, keyset pagination instead of OFFSET, multi-row INSERT, unnest arrays and COPY instead of row-by-row writes, INSERT ... ON CONFLICT for upserts, RETURNING (old/new on PG 18+) instead of a read-back, and named columns instead of SELECT *.
metadata:
  verified: 2026-10-18
---

# Query patterns: fewer statements, less work per statement

## The decision

Every statement an application sends costs a network round trip, a parse/bind/execute cycle and a wait on a pooled connection, and every row the server reads to throw away costs CPU and buffer reads. The shape of a query decides both: a list endpoint can be one statement or twenty-one, page 500 can read 20 rows or 10,000, and loading 1,000 rows can be one statement or 1,000. None of this shows in a demo with ten rows. This skill fixes how reads and writes are shaped so a request does the fewest statements and reads the fewest rows that give the right answer. Driver and pool specifics (how to send arrays, batches and `COPY` from Go) live in [go-skills `sql-queries-and-transactions`](https://github.com/rafapeixer/go-skills/blob/main/skills/sql-queries-and-transactions/SKILL.md); this skill is the SQL the database sees.

## The rule

1. Return a page and its small, bounded child rows in one statement: put the page's `WHERE`, `ORDER BY` and `LIMIT` in a subquery and join it to `LEFT JOIN LATERAL (SELECT array_agg(...) ...)` (or `json_agg`), never one query per parent and not a second query for the children.
2. Paginate with a keyset, `WHERE (created_at, id) < ($2, $3) ORDER BY created_at DESC, id DESC LIMIT n`, backed by an index whose columns match that order and end in a unique column, never with `OFFSET`.
3. Write many rows in one statement, with a multi-row `INSERT`, `INSERT ... SELECT FROM unnest($1::type[], $2::type[])`, or `COPY` for bulk loads, never with an `INSERT` per row.
4. Upsert with `INSERT ... ON CONFLICT (key) DO UPDATE SET col = EXCLUDED.col WHERE t.col IS DISTINCT FROM EXCLUDED.col` (or `DO NOTHING`), never with a `SELECT` followed by an `INSERT` or `UPDATE`.
5. Get the written row back with `RETURNING`, and on PostgreSQL 18+ use `RETURNING old.col, new.col` when you need the value before the change, never with a `SELECT` after the write.
6. Name the columns the caller uses in every application query, never `SELECT *`.

## Why

**Rule 1.** A list of 20 orders that loads items per order is 21 statements; at 1 ms of round trip each, that is 20 ms of latency before any statement is slow, and the bad example counts them in `pg_stat_statements`: the item lookup ran 20 times. A second query with `WHERE order_id = ANY($1)` fixes the N+1 but is still a second round trip on every request. A `LATERAL` subquery can reference columns of the rows before it in the `FROM` list and runs once per such row ([LATERAL subqueries](https://www.postgresql.org/docs/current/queries-table-expressions.html#QUERIES-LATERAL)), so joining it to a subquery that already applied the `LIMIT` gives one index lookup per row on the page and none for rows the limit discards. The good example's plan uses only index scans, has no `Sort`, and reads 57 of the 300,000 item rows. `array_agg` returns parallel arrays that binary drivers decode without JSON; `json_agg` is the choice when the client wants nested objects. `coalesce(..., '{}')` keeps parents with no children. In this project's benchmark, the [go-skills orders-api](https://github.com/rafapeixer/go-skills/blob/main/BENCHMARKS.md) on one 2 vCPU / 1 GiB replica, replacing the second `= ANY` query with this one `LATERAL` statement cut CPU per request by about 9–16% (9% across three verification runs, 16% in the run that measured it alone), and was half of doubling capacity within the SLO from 5,000 to 10,000 req/s (the other half was a correctly sized bulkhead).

**Rule 2.** "The rows skipped by an `OFFSET` clause still have to be computed inside the server; therefore a large `OFFSET` might be inefficient" ([LIMIT and OFFSET](https://www.postgresql.org/docs/current/queries-limit.html)). The bad example proves it: the last page of a customer with 10,000 orders reads 10,000 index entries to return 20, so cost grows linearly with depth. A keyset page starts where the previous page ended, using a row-wise comparison ([row constructor comparison](https://www.postgresql.org/docs/current/functions-comparisons.html#ROW-WISE-COMPARISON)) that a B-tree on `(customer_id, created_at, id)` turns into a range scan: the good example's deepest page reads 20 rows, the same as the first, with no `Sort`. `OFFSET` is also wrong, not only slow: a row inserted between two requests shifts the window, and the bad example shows the next page repeating a row the client already has, while the keyset page in the good example has no overlap. The unique `id` at the end of the key breaks ties in `created_at`, so no row is skipped at a page boundary. The cost: no "jump to page 37" and no cheap total count.

**Rule 3.** One statement per row means one parse, plan and execute per row, and from a client in autocommit one round trip and one commit per row. The PostgreSQL docs say "If you allow each insertion to be committed separately, PostgreSQL is doing a lot of work for each row that is added", and to "Use `COPY` to load all the rows in one command, instead of using a series of `INSERT` commands" because it "incurs significantly less overhead for large data loads" ([Populating a Database](https://www.postgresql.org/docs/current/populate.html)). `unnest` with one array parameter per column keeps one statement with a fixed text for any number of rows, so it has one prepared plan and one `pg_stat_statements` entry, where a multi-row `VALUES` list changes text with every row count. Combine it with a data-modifying `WITH` to insert an order and its items in one statement, as the good example does. The bad example's loop runs 1,000 `INSERT` statements for 1,000 rows.

**Rule 4.** A check-then-insert is two statements and a race: two sessions both see no row, and the second `INSERT` fails with `23505 unique_violation`, as the bad example shows. `ON CONFLICT DO UPDATE` "guarantees an atomic `INSERT` or `UPDATE` outcome; provided there is no independent error, one of those two outcomes is guaranteed, even under high concurrency" ([INSERT](https://www.postgresql.org/docs/current/sql-insert.html#SQL-ON-CONFLICT)). It needs a unique index or constraint on the conflict target. `EXCLUDED` is the row proposed for insertion, and the `WHERE ... IS DISTINCT FROM` skips rows that would not change, so a retried batch writes no new row versions: in the good example the rerun of a 3-row batch writes only the one row whose value changed. The `MERGE` docs point to `ON CONFLICT` as the statement that can run an `UPDATE` if a concurrent `INSERT` occurs, and state that the two are not interchangeable ([MERGE](https://www.postgresql.org/docs/18/sql-merge.html)); for concurrent upserts, use `ON CONFLICT`.

**Rule 5.** "Use of `RETURNING` avoids performing an extra database query to collect the data, and is especially valuable when it would otherwise be difficult to identify the modified rows reliably" ([Returning Data from Modified Rows](https://www.postgresql.org/docs/18/dml-returning.html)). A read-back after the write is a second round trip and can see another transaction's change in between. PostgreSQL 18 adds `old` and `new` to `RETURNING` for `INSERT`, `UPDATE`, `DELETE` and `MERGE` ([PostgreSQL 18 released](https://www.postgresql.org/about/news/postgresql-18-released-3142/)), which replaces the `SELECT ... FOR UPDATE` some code runs just to log the previous value; with `ON CONFLICT DO UPDATE`, `old` is non-null for the rows that conflicted. On PostgreSQL 15–17, `RETURNING` returns only the new values.

**Rule 6.** "The query must reference only columns stored in the index" for an index-only scan ([Index-Only Scans](https://www.postgresql.org/docs/current/indexes-index-only-scans.html)); `SELECT *` never meets that, so every row visits the heap, as the bad example's plan shows, while the named-column list query in the good example reads only the index. `SELECT *` also sends columns the caller ignores, including large `text` and `jsonb` values the server must fetch and send, and it changes shape when a migration adds a column, which breaks code that maps columns by position.

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
FROM (
    SELECT id, total_cents, created_at FROM orders
    WHERE customer_id = 3
    ORDER BY created_at DESC, id DESC
    LIMIT 20
) o
LEFT JOIN LATERAL (
    SELECT array_agg(sku ORDER BY sku) AS skus, array_agg(qty ORDER BY sku) AS qtys
    FROM order_items WHERE order_id = o.id
) i ON true;
```

```sql
SELECT id, created_at FROM orders
WHERE customer_id = 3 AND (created_at, id) < (after_created, after_id)
ORDER BY created_at DESC, id DESC
LIMIT 20
```

```sql
INSERT INTO order_items (order_id, sku, qty)
SELECT new_order.id, item.sku, item.qty
FROM new_order, unnest(ARRAY['sku-a', 'sku-b', 'sku-c'], ARRAY[2, 1, 5]) AS item (sku, qty)
```

```sql
ON CONFLICT (sku) DO UPDATE SET available = EXCLUDED.available
WHERE s.available IS DISTINCT FROM EXCLUDED.available
RETURNING sku
```

On 100,000 orders and 300,000 items, the test asserts that the page returns 20 orders with their own items (and an empty array for the order that has none), that its plan has index scans and no `Seq Scan` or `Sort`, and that it reads at most 60 item rows. The keyset page is an `Index Only Scan` with no `Sort`, its deepest page reads 20 rows, and a row inserted between two requests does not duplicate a row on the next page. One statement inserts an order and its three items, `COPY` loads two more, the upsert rerun writes only the changed row, `RETURNING` gives back the new status, and on PostgreSQL 18 (gated on `server_version_num` inside the test) `RETURNING old.status, new.status` returns both versions.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: OFFSET reads and throws away every earlier row. The last page of
-- this customer reads 10,000 index entries to return 20; cost grows with depth.
SELECT assert_true(
scanned_rows($q$SELECT id, created_at FROM orders WHERE customer_id = 3
ORDER BY created_at DESC, id DESC LIMIT 20 OFFSET 9980$q$, 'orders') = 10000,
'the deep OFFSET page reads 10,000 rows to return 20');
```

```sql
FOR o IN 1..250 LOOP
FOR n IN 1..4 LOOP
-- MISTAKE: one INSERT per row. 1,000 rows cost 1,000 statements (and,
-- from a client in autocommit, 1,000 round trips and 1,000 commits)
-- where one unnest INSERT or a COPY does the same work.
INSERT INTO order_items (order_id, sku, qty) VALUES (o, 'extra-' || n, 1);
```

The assertions describe the bad outcome: the deep `OFFSET` page reads 10,000 rows, an insert between requests makes one row appear on two `OFFSET` pages, `pg_stat_statements` (with `track = 'all'`) counts 20 item lookups for a 20-order page and 1,000 `INSERT` statements for 1,000 rows, the check-then-insert loses to a concurrent writer with `23505`, and `SELECT *` rules out an `Index Only Scan`. If any of these stops happening, the example fails.

## Checklist

When reviewing SQL under this skill, confirm:

- [ ] No code path runs a query per row of a result; small, bounded children come back with their parents through `LEFT JOIN LATERAL` with `array_agg` or `json_agg`.
- [ ] The `LIMIT` of a page sits in a subquery before the `LATERAL` join, so the child lookup runs only for rows on the page.
- [ ] No list query uses `OFFSET` beyond a small, bounded admin table; pages use a row comparison on a key that ends in a unique column.
- [ ] An index matches the keyset's equality columns, sort columns and tie-breaker in order, and the page's plan has no `Sort`.
- [ ] Writes of many rows use one multi-row `INSERT`, `unnest` arrays or `COPY`, not a loop of single-row statements.
- [ ] Upserts use `INSERT ... ON CONFLICT` on a unique index or constraint, and `DO UPDATE` skips unchanged rows with `IS DISTINCT FROM`.
- [ ] No `SELECT` follows an `INSERT`, `UPDATE` or `DELETE` only to read what it wrote; `RETURNING` (with `old`/`new` on PG 18+) gives it back.
- [ ] Application queries name their columns; no `SELECT *` outside ad hoc sessions.

## When not to apply

- **Large or unbounded child sets.** A customer's orders or a post's comments can grow without limit; one array per parent then grows with it. Load them with their own keyset-paged query, or with a second `= ANY($1)` query for a page of parents.
- **Small, fixed admin tables.** A back-office table of a few thousand rows that needs page numbers can use `OFFSET`; switch to a keyset before the table or the depth grows.
- **Very large one-off loads.** For millions of rows, `COPY` into a staging table and then one `INSERT ... SELECT ... ON CONFLICT` keeps the load fast and the upsert set-based; follow the rest of [Populating a Database](https://www.postgresql.org/docs/current/populate.html) (drop and recreate indexes, raise `maintenance_work_mem`) only for initial loads, not for a live table.
- **Synchronizing a whole table from a source.** When rows must also be deleted when they disappear from the source and no other writer touches the table, `MERGE` (with `WHEN NOT MATCHED BY SOURCE` on PG 17+) states it in one statement; under concurrent writers keep `ON CONFLICT`.
- **Ad hoc and exploratory sessions.** `SELECT *` in `psql` while investigating is fine; the rule is for queries that ship in application code, views and functions.
