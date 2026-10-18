---
name: db-explain
description: Use when the user asks why a specific SELECT is slow on their PostgreSQL or MySQL database, wants its plan explained, or asks which index or rewrite would fix it. Read-only: runs plain EXPLAIN (FORMAT JSON), and EXPLAIN ANALYZE only for a SELECT, only with the user's consent and under a timeout, reads index and table statistics for the tables involved, and proposes an index or rewrite as a migration without applying it.
disable-model-invocation: true
argument-hint: "<the SELECT, or a file:line where the query is built> [env var holding the connection string]"
metadata:
  verified: 2026-10-18
---

# Explain a query

## Purpose

The user gets the plan of one query explained in plain words: where the time or the rows go, why the planner chose that path, and the one change most likely to fix it. That change is either an index, delivered as a migration with its rollback, or a rewrite of the SQL. Each comes with the plan line that proves it worked. Nothing is changed on the database.

## Safety

- **Read-only is enforced by the database role.** Connect with the role from `skills/db-audit/setup/pg-audit-role.sql` or `skills/db-audit/setup/mysql-audit-role.sql`. The user creates it; you never run setup files.
  - **Privileges:** `EXPLAIN` needs the same privileges as the statement it explains ([MySQL EXPLAIN](https://dev.mysql.com/doc/refman/8.4/en/explain.html); Postgres checks table permissions the same way). So this workflow needs `SELECT` on the tables involved: the optional, consented grant in the setup file. Ask for the narrow per-table grant before `pg_read_all_data`.
  - **Why the role:** client-side read-only modes are not a boundary. AWS's MCP servers were bypassed through `COPY ... TO PROGRAM` ([CVE-2026-87911](https://github.com/awslabs/mcp/security/advisories/GHSA-fph8-pg5w-78fv)) and SQL comments ([CVE-2026-85788](https://github.com/awslabs/mcp/security/advisories/GHSA-x25m-ph3m-3r9q)). AWS says the role's permissions are the effective limit.
- **Run `queries/<engine>/00-session.sql` first.** Stop under the same conditions as `/db-skills:db-audit`: superuser, a risky role or privilege, writable tables, or a session that is not read-only.
- **Plain EXPLAIN by default.** It plans the statement without running it.
- **`EXPLAIN ANALYZE` runs the statement.** Postgres says the statement is actually executed and its side effects happen as usual ([EXPLAIN](https://www.postgresql.org/docs/current/sql-explain.html)). MySQL's `EXPLAIN ANALYZE` runs the statement too, including multi-table `UPDATE` and `DELETE` ([EXPLAIN](https://dev.mysql.com/doc/refman/8.4/en/explain.html)). Use it only when all of these hold:
  1. The statement is a single `SELECT`, `WITH ... SELECT` with no data-modifying CTE, `TABLE` or `VALUES`.
  2. It has no `FOR UPDATE`/`FOR SHARE` (or other locking clause), no `SELECT ... INTO`, and calls no function you cannot see is read-only: `nextval`, advisory locks, `dblink`, user functions.
  3. The user said yes after seeing the exact statement, the host, whether it is a replica, and the timeout.
  4. It runs inside `BEGIN READ ONLY` / `START TRANSACTION READ ONLY` with a statement timeout, and ends in `ROLLBACK`.

  In a read-only transaction, Postgres rejects `SELECT ... FOR UPDATE` and the timeout cancels a run that is too long. Those are a second guard, not the reason to try.
- **Never `EXPLAIN ANALYZE` a write.** Not even inside `BEGIN ... ROLLBACK`: row locks are held until the rollback, triggers fire, and sequences advance. The audit role also cannot plain-`EXPLAIN` a write, because it holds no write privilege. To see how a write finds its rows, explain the equivalent `SELECT` with the same `FROM` and `WHERE`.
- **Literals.**
  - The user's query and its parameter values may contain personal data. Use real values only in the session, never in the report.
  - Plan JSON repeats constants in `Filter`, `Index Cond` and `attached_condition`: replace them with `?` when you quote plan lines.
  - The helper files never read `pg_stats.most_common_vals`/`histogram_bounds` or histogram buckets.
- **Never** run `ANALYZE` or `ANALYZE TABLE`, change settings with `SET GLOBAL`, create indexes or extensions, or reset statistics. When stale statistics are the cause, the report tells the user to run `ANALYZE` themselves.

## Steps

1. **Get the query.** Take it from the argument, or ask. If the user points at code (an ORM call, a query builder), get the SQL it actually sends. Prefer the normalized text from `05-statement-stats.sql` (PG) or `04-statement-stats.sql` (MySQL), or the app's SQL log, over a reconstruction. If the query has parameters:
   - PG 16+: plan it as a generic plan with `GENERIC_PLAN` ([EXPLAIN](https://www.postgresql.org/docs/current/sql-explain.html)). That option cannot be combined with `ANALYZE`.
   - Otherwise: ask for representative values, including a common value and a rare one, since they can produce different plans.
2. **Classify it** with the rules in Safety. A write gets rewritten as its row-finding `SELECT`. More than one statement means refuse, and ask for one.
3. **Guard.** Run `00-session.sql`. Note the version and whether this is a replica.
4. **Collect context.** List the tables the query reads. Run the helper files after the one allowed edit: replace the table names in the `ARRAY[...]`/`IN (...)` literal, and the fragment in the `LIKE` pattern.
   - PG: `01-indexes-for-tables`, `02-table-stats`, `03-column-stats`, `04-planner-settings`, `05-statement-stats` (skip it without pg_stat_statements).
   - MySQL: `01-indexes-for-tables`, `02-table-stats`, `03-planner-settings`, `04-statement-stats`.
5. **Plain plan.** Build the statement at run time from the user's query:
   - PostgreSQL: `EXPLAIN (FORMAT JSON, SETTINGS) <query>`; with parameters on 16+, `EXPLAIN (GENERIC_PLAN, FORMAT JSON) <query>`.
   - MySQL: `EXPLAIN FORMAT=JSON <query>`; add `EXPLAIN FORMAT=TREE <query>` when the JSON is hard to read. MySQL 9.x defaults the JSON to layout version 2, which has no `access_type` or `key` fields; run `SET SESSION explain_json_format_version = 1;` first so the plan has the fields this workflow reads ([explain_json_format_version](https://dev.mysql.com/doc/refman/9.7/en/server-system-variables.html#sysvar_explain_json_format_version)).
6. **Measured plan, only with consent.** Offer it when estimates and reality may differ, for example a large row-estimate gap or a production mean far from the plan's cost. Show the exact block, then run it only on a yes:

   ```sql
   -- PostgreSQL (BUFFERS is automatic on 18; TIMING OFF lowers overhead)
   BEGIN READ ONLY;
   SET LOCAL statement_timeout = '5s';
   SET LOCAL lock_timeout = '1s';
   EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) <select>;
   ROLLBACK;
   ```

   ```sql
   -- MySQL (EXPLAIN ANALYZE prints TREE format only)
   SET SESSION max_execution_time = 5000;
   START TRANSACTION READ ONLY;
   EXPLAIN ANALYZE SELECT /*+ MAX_EXECUTION_TIME(5000) */ ...;
   ROLLBACK;
   ```

   A timeout is a finding in itself: report "runs longer than 5 s". Do not raise the timeout without asking.
7. **Read the plan.** Find the nodes that hold most of the cost or time, and the row estimates that are wrong by 10x or more. Then match them to a cause:

   | What the plan shows | Likely cause | Fix to propose | Decision skill |
   |---|---|---|---|
   | PG `Seq Scan` with `Rows Removed by Filter` far above rows returned; MySQL `access_type: ALL`, high `rows_examined_per_scan`, low `filtered` | no index for the filter | composite index: equality columns first, then the range or sort column | pg-indexing / MySQL indexing skill |
   | `Index Scan` followed by a `Filter` that drops most rows; MySQL `used_key_parts` shorter than the index | wrong column order, or a range before an equality column | reorder or extend the index | pg-indexing |
   | `Sort` with `external merge Disk`; MySQL `using_filesort` on a large row count | no index delivers the order, or sort memory is too small | index matching `WHERE` + `ORDER BY`; else a per-role `work_mem` | pg-indexing, pg-config-by-size |
   | `Hash` with `Batches` > 1; MySQL `using_temporary_table` spilling | hash or temp table larger than memory | reduce rows earlier, or raise memory per role | pg-config-by-size |
   | `Nested Loop` with many `loops` on an inner `Seq Scan` | missing index on the join column | index the inner table's join column (often an FK) | pg-indexing |
   | `Limit` above a large `Offset`, or a sort of every row for the first page | OFFSET pagination | keyset pagination on an indexed key | pg-query-patterns |
   | Filter on `lower(col)`, `col::text`, `date(col)`; MySQL comparing a string column with a number | function or type mismatch hides the index | rewrite to compare the bare column, or an expression index | pg-indexing, pg-query-patterns |
   | `Index Only Scan` with high `Heap Fetches` | visibility map stale, vacuum behind | autovacuum tuning for the table | pg-vacuum-and-bloat |
   | Estimate far from actual on correlated columns | planner assumes independence | `CREATE STATISTICS` on the columns ([docs](https://www.postgresql.org/docs/current/sql-createstatistics.html)), then the user runs `ANALYZE` | pg-observability |
   | Estimate far from actual and `n_mod_since_analyze` high or `last_analyze` old | stale statistics | the user runs `ANALYZE <table>`; check autovacuum settings | pg-vacuum-and-bloat |
   | Large `JIT` time on a short query | JIT cost above the query's own cost | `jit = off` for the OLTP role | pg-config-by-size |

   Use the node and field definitions from [Using EXPLAIN](https://www.postgresql.org/docs/current/using-explain.html) and [EXPLAIN output format](https://dev.mysql.com/doc/refman/8.4/en/explain-output.html). A fix must remove most of the cost, not 10%. If no index or rewrite does that, say so and point to the data model or caching.
8. **Optional what-if (PG).** If the `hypopg` extension is already installed, a hypothetical index plus plain `EXPLAIN` shows whether the planner would use the proposed index. It is session-local and builds nothing ([hypopg](https://github.com/HypoPG/hypopg)). Installing the extension is DDL: suggest it, do not do it.
9. **Write the fix.**
   - **Postgres index:** `SET lock_timeout = '5s'; CREATE INDEX CONCURRENTLY IF NOT EXISTS ...` outside a transaction ([CREATE INDEX](https://www.postgresql.org/docs/current/sql-createindex.html)). Rollback: `DROP INDEX CONCURRENTLY IF EXISTS ...`.
   - **MySQL index:** `SET SESSION lock_wait_timeout = 5; ALTER TABLE t ADD INDEX ix (...), ALGORITHM=INPLACE, LOCK=NONE` ([online DDL](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-operations.html)). Rollback: `ALTER TABLE t DROP INDEX ix`.
   - **Format:** use the repo's migration tool format. Create the file only if the user asks.
   - **Rewrite:** show the before and after SQL, and where in the code it changes.
10. **Report** in the format below.

## Output

```
Query: <redacted, normalized text>   Engine: <engine version>, <primary|replica>
Plan: <estimated (EXPLAIN) | measured (EXPLAIN ANALYZE, with consent)>   Parameters: <generic plan | sample values, not shown>
Production: <calls, mean, max from pg_stat_statements / digest summary, or "not available">
```

**Where the cost is**: the 1–3 nodes that matter, quoting plan lines with constants redacted:

| Node | Table / index | Estimated rows | Actual rows | Share of cost or time | Problem |
|---|---|---|---|---|---|

**Findings**: ordered by impact:

| # | Severity | Finding | Evidence | Related skill | Proposed migration or rewrite (rollback) | How to verify |
|---|---|---|---|---|---|---|
| E1 | HIGH | `orders` filtered by `customer_id` and sorted by `created_at` with no matching index | `Seq Scan on orders`, Rows Removed by Filter: 2,400,000 per call; mean 48 ms over 2.1M calls | pg-indexing | `CREATE INDEX CONCURRENTLY orders_customer_created_idx ON orders (customer_id, created_at)` (rollback `DROP INDEX CONCURRENTLY orders_customer_created_idx`) | plain `EXPLAIN` shows `Index Scan using orders_customer_created_idx` with no `Sort`; `mean_exec_time` falls after deploy |

The row above is an example of the format.

After the table, give the full migration or rewrite, the write cost of the new index (one more index to maintain on every insert, and on every update of its columns), and anything the user must run themselves, such as `ANALYZE`. Write the report to a Markdown file in the repo only if the user asks.

## When not to use

- The user wants a health check of the whole database, not one query: use `/db-skills:db-audit`.
- The query is fast alone but slow under load because of lock waits or connection queuing: the plan will look fine. Use `/db-skills:db-audit` (sessions and lock waits) or `/db-skills:db-connection-budget`.
- The statement is an `INSERT`, `UPDATE`, `DELETE` or DDL and the user wants it measured: this workflow will not execute it. Measure it on a staging copy the user controls.
- The audit role has no `SELECT` on the tables and the user declines the grant: `EXPLAIN` cannot plan the query. Ask for an explain from someone with access, or use a staging copy.
- The tables on the connected instance are much smaller than production, as on a laptop or fresh staging: the planner will choose differently. Explain against production or a replica.
