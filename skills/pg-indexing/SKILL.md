---
name: pg-indexing
description: Use when adding, reviewing or removing PostgreSQL indexes, writing a migration that creates one, or a query plan shows a Seq Scan or Sort you did not expect. Covers composite column order (equality, then range, then sort), covering INCLUDE indexes, partial and expression indexes, foreign key indexes, duplicate and unused indexes, and B-tree skip scan (PG 18+).
metadata:
  verified: 2026-10-18
---

# Indexing

## The decision

Every index is a bet: it makes some reads cheaper and every write, vacuum and backup more expensive. The decision is which indexes to create for the queries you actually run, in what column order, and which to drop. Get it wrong and the costs are concrete: a composite index in the wrong order still gets used but reads hundreds of pages to return 15 rows, an unindexed foreign key turns every parent `DELETE` into a full scan of the child table, an index on `email` does nothing for `lower(email)`, and a redundant index costs space and write time on every `INSERT` without ever being read. This skill fixes how you pick an index for a query and when you remove one.

## The rule

1. Order composite B-tree keys as equality columns first, then the one range or `ORDER BY` column; columns after the first range column only filter, they do not narrow the scan.
2. Add `INCLUDE (...)` only for the few narrow columns a hot query selects, so it becomes an Index Only Scan.
3. Use a partial index (`WHERE status = 'pending'`) for a small hot subset, and write the same literal predicate in the query.
4. Index the exact expression the query uses (`lower(email)`), or change the query to match the index; a plain column index does not serve a function of that column.
5. Index the referencing columns of every foreign key, as the leading columns of some index, when the parent is ever deleted, its key updated, or the tables joined on it.
6. Drop an index whose key columns are a leading prefix of another index, and one with `idx_scan = 0` on every node over a full business cycle.
7. On PG 18+, a leading column with few distinct values no longer blocks filters on later columns (skip scan), so do not add a second index just to reorder them; on 15 to 17 you still need it.
8. On a live table, build and drop indexes with `CREATE INDEX CONCURRENTLY` / `DROP INDEX CONCURRENTLY`, as described in [pg-online-migrations](../pg-online-migrations/SKILL.md).

## Why

**Rule 1.** The PostgreSQL docs state the exact rule: "equality constraints on leading columns, plus any inequality constraints on the first column that does not have an equality constraint, will always be used to limit the portion of the index that is scanned. Constraints on columns to the right of these columns are checked in the index ... but they do not necessarily reduce the portion of the index that has to be scanned" ([Multicolumn Indexes](https://www.postgresql.org/docs/18/indexes-multicolumn.html)). With `(customer_id, created_at)`, the query `WHERE customer_id = 42 AND created_at >= '2026-03-01' ORDER BY created_at LIMIT 20` touches 4 buffers in the good example. With `(created_at, customer_id)` the same query still uses the index, but walks every order since March and touches 837 buffers in the bad example, about 200 times more. Putting the sort column right after the equality columns also lets the index return rows in order: "This allows a query's `ORDER BY` specification to be honored without a separate sorting step", and with `LIMIT n` "the first n rows can be retrieved directly, without scanning the remainder at all" ([Indexes and ORDER BY](https://www.postgresql.org/docs/18/indexes-ordering.html)). The docs also advise that "Indexes with more than three columns are unlikely to be helpful unless the usage of the table is extremely stylized."

**Rule 2.** An index-only scan needs every column the query references to be in the index, and pays off only when "a significant fraction of the table's heap pages have their all-visible map bits set", which vacuum maintains. The docs warn: "It's wise to be conservative about adding non-key payload columns to an index, especially wide columns ... non-key columns duplicate data from the index's table and bloat the size of the index", and an index tuple that exceeds the maximum size makes the insert fail ([Index-Only Scans and Covering Indexes](https://www.postgresql.org/docs/18/indexes-index-only-scans.html)). B-tree deduplication is never used with indexes that have a non-key column ([CREATE INDEX](https://www.postgresql.org/docs/18/sql-createindex.html)). On a table where most rows change constantly, the heap is visited anyway, so `INCLUDE` only adds size.

**Rule 3.** A partial index "reduces the size of the index, which will speed up those queries that do use the index. It will also speed up many table update operations because the index does not need to be updated in all cases." In the good example the pending-orders index is 88 kB against 9.5 MB for a full index on the same table. The catch: "a partial index can be used in a query only if the system can recognize that the `WHERE` condition of the query mathematically implies the predicate", matching happens at planning time, so a parameter (`status = $1`) does not match `status = 'pending'`. Do not create one partial index per category value; the docs call that "a bad idea" and recommend a single index on `(category, data)` or partitioning ([Partial Indexes](https://www.postgresql.org/docs/18/indexes-partial.html)).

**Rule 4.** `WHERE lower(email) = ...` can use an index "if one has been defined on the result of the `lower(col1)` function" ([Indexes on Expressions](https://www.postgresql.org/docs/18/indexes-expressional.html)). In the bad example the index on `email` exists and the query still does a Seq Scan. Expression indexes cost more on writes, because "the derived expression(s) must be computed for each row insertion and non-HOT update", so index the expression only when a hot query uses it.

**Rule 5.** "Since a `DELETE` of a row from the referenced table or an `UPDATE` of a referenced column will require a scan of the referencing table for rows matching the old value, it is often a good idea to index the referencing columns too", and PostgreSQL "does not automatically create an index on the referencing columns" ([Constraints: Foreign Keys](https://www.postgresql.org/docs/18/ddl-constraints.html#DDL-CONSTRAINTS-FK)). In the bad example the lookup behind that check is a Seq Scan over 300k orders, once per deleted customer. An existing composite index that leads with the FK column is enough; you do not need a separate single-column one.

**Rule 6.** "Indexes also add overhead to the database system as a whole, so they should be used sensibly" ([Indexes](https://www.postgresql.org/docs/18/indexes.html)). Each index is written on every insert and on every update that is not HOT, and an update that modifies any indexed column cannot be HOT at all ([Heap-Only Tuples](https://www.postgresql.org/docs/18/storage-hot.html)). The redundant `(status)` index in the bad example takes 2 MB and serves nothing `(status, created_at)` cannot. `pg_stat_all_indexes.idx_scan` counts scans and `last_idx_scan` (PG 16+) gives the last one ([Cumulative Statistics](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-ALL-INDEXES-VIEW)); these counters are kept per server, so check the primary and each replica before dropping, and keep unique indexes that enforce a constraint even when nobody reads them.

**Rule 7.** PG 18 added B-tree skip scan: multicolumn indexes can now be used "when there are no restrictions on the first or early indexed columns (or there are non-equality ones), and there are useful restrictions on later indexed columns" ([PG 18 release notes](https://www.postgresql.org/docs/18/release-18.html)). The docs add that the planner takes this path "only when there are so few distinct `x` values that the planner expects the scan to skip over most of the index"; with many distinct leading values it prefers a sequential scan ([Multicolumn Indexes](https://www.postgresql.org/docs/18/indexes-multicolumn.html)). In the good example, a filter on `created_at` alone uses `(status, created_at)` (3 statuses) on PG 18 and is a Seq Scan on PG 15. Skip scan does not fix a high-cardinality leading column; rule 1 still decides the order.

**Rule 8.** A plain `CREATE INDEX` "locks out writes (but not reads)" on the table for the whole build ([CREATE INDEX](https://www.postgresql.org/docs/18/sql-createindex.html)). `CONCURRENTLY` avoids that, cannot run in a transaction block, and can leave an INVALID index behind; [pg-online-migrations](../pg-online-migrations/SKILL.md) covers the procedure and the cleanup.

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
CREATE INDEX orders_customer_created_idx ON orders (customer_id, created_at) INCLUDE (total);
CREATE INDEX orders_pending_created_idx ON orders (created_at) WHERE status = 'pending';
CREATE INDEX customers_email_lower_idx ON customers (lower(email));
CREATE INDEX orders_status_created_idx ON orders (status, created_at);
VACUUM ANALYZE orders;

plan_has($q$SELECT created_at, total FROM orders WHERE customer_id = 42 AND created_at >= '2026-03-01' ORDER BY created_at LIMIT 20$q$, 'Index Only Scan'),
index_used($q$SELECT id, created_at FROM orders WHERE status = 'pending' ORDER BY created_at LIMIT 50$q$, 'orders_pending_created_idx'),
index_used($q$SELECT id FROM customers WHERE lower(email) = 'user42@example.com'$q$, 'customers_email_lower_idx'),
```

With 20k customers and 300k orders, the test asserts on PG 15 and PG 18 that:

- `WHERE customer_id = ? AND created_at >= ? ORDER BY created_at LIMIT 20` is an Index Only Scan with no Sort node and touches fewer than 10 buffers.
- The pending queue uses the partial index in `created_at` order, and that index is under 5% of the size of a full one.
- The case-insensitive login uses the expression index.
- The foreign key lookup `WHERE customer_id = ?` never scans `orders`, and a catalog query finds no foreign key without an index leading with its columns and no index that is a prefix of another.
- On PG 18+, `WHERE created_at >= ? AND created_at < ?` uses `(status, created_at)` through skip scan; on PG 15 the same query is a Seq Scan, so the test checks each version for its own behavior.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: range column first. The scan walks every order since March to find one customer's 15 rows.
CREATE INDEX orders_created_customer_idx ON orders (created_at, customer_id);

-- MISTAKE: plain column index, but the login query compares lower(email). The index is never used.
CREATE INDEX customers_email_idx ON customers (email);

-- MISTAKE: a second index on the same leading column, "just in case". Every insert pays for both.
CREATE INDEX orders_status_idx ON orders (status);
CREATE INDEX orders_status_created_idx ON orders (status, created_at);

-- MISTAKE: no index leads with orders.customer_id, so each DELETE FROM customers scans all of orders.
```

The assertions describe the damage: the customer query is no longer index-only and touches more than 500 buffers (837 in practice, against 4); the latest orders for a customer are a Seq Scan or a Sort; the foreign key lookup is a Seq Scan and the catalog query reports the unindexed foreign key; `lower(email)` is a Seq Scan while `customers_email_idx` sits unused; and the catalog query reports `orders_status_idx` as a prefix of `orders_status_created_idx`, still taking more than 1 MB.

## Checklist

When reviewing schema or SQL under this skill, confirm:

- [ ] Each new index names the query it serves, and that query's plan uses it (`EXPLAIN`).
- [ ] Composite keys list equality columns first, then the single range or `ORDER BY` column, with no more than three key columns without a stated reason.
- [ ] `INCLUDE` columns are narrow, selected by a hot query, and the table is mostly all-visible.
- [ ] Each partial index predicate appears as a literal in the queries meant to use it, not as a bind parameter.
- [ ] Each expression index matches the query expression exactly (`lower(email)`, not `email`).
- [ ] Every foreign key column set is the leading part of some index on the referencing table.
- [ ] No index is a leading prefix of another non-unique index on the same table.
- [ ] Indexes proposed for removal show `idx_scan = 0` on the primary and every replica over a full cycle, and do not enforce a constraint.
- [ ] A second index added only to reorder a low-cardinality leading column is justified by a server below PG 18.
- [ ] Migrations on existing tables use `CONCURRENTLY` per [pg-online-migrations](../pg-online-migrations/SKILL.md).

## When not to apply

- Small tables (a few thousand rows, a handful of pages): a sequential scan is as fast as any index, so add only the primary key and the indexes constraints need.
- Bulk loads into a freshly created table: load first, then create the indexes; "Creating an index on pre-existing data is quicker than updating it incrementally as each row is loaded" ([Populating a Database](https://www.postgresql.org/docs/18/populate.html)).
- Very large append-only tables queried by time range, where rows sit in time order on disk: consider a BRIN index, which is "very small" and built for columns with "natural correlation with their physical location within the table" ([BRIN Indexes](https://www.postgresql.org/docs/18/brin.html)); this skill's B-tree rules do not decide that case.
- `jsonb` containment, arrays and `LIKE '%term%'` searches need GIN or GiST (with `pg_trgm` for substring search), not a B-tree; column order rules here do not apply to them.
- Foreign keys to parent rows that are never deleted and whose key never changes, and that you never join from the parent side (for example a lookup table of countries): the index on the child column can be skipped if no query filters by it.
