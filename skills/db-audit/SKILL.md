---
name: db-audit
description: Use when the user asks to audit, health-check or review the performance of their own PostgreSQL or MySQL database, including RDS and Aurora. Read-only: connects with a read-only role, reads statistics and catalogs (top statements, cache hit, unused, duplicate and missing indexes, sequential scans, vacuum and purge lag, long transactions, lock waits, connections) and proposes fixes as migration files without applying them.
disable-model-invocation: true
argument-hint: "[env var holding the connection string, e.g. DATABASE_URL] [postgres|mysql]"
metadata:
  verified: 2026-10-18
---

# Database audit

## Purpose

The user gets a short report of what costs the most on **their** database right now, ordered by impact, where each finding carries its evidence (numbers and the statistics window they cover), the decision skill that explains the fix, a migration with its rollback, and the query that proves the fix worked. Nothing is changed: the user reviews the migrations and ships them through their normal pipeline.

## Safety

**Read-only is enforced by the database role, not by you and not by an MCP server.** Client-side read-only modes keep failing. AWS's own MCP servers shipped two read-only bypasses in September 2026:

- [CVE-2026-87911 / GHSA-fph8-pg5w-78fv](https://github.com/awslabs/mcp/security/advisories/GHSA-fph8-pg5w-78fv) (critical): in `awslabs.postgres-mcp-server` before 1.1.7, read-only mode let `COPY ... TO PROGRAM` through. It ran OS commands when the role had superuser or `pg_execute_server_program`. Roles with minimal privileges were not affected.
- [CVE-2026-85788 / GHSA-x25m-ph3m-3r9q](https://github.com/awslabs/mcp/security/advisories/GHSA-x25m-ph3m-3r9q): in `awslabs.mysql-mcp-server` up to 1.0.21, SQL comments placed between keywords got past the read-only check. The impact depended on the account holding `FILE`.

AWS's advisory calls read-only mode a best-effort safeguard and not a hard security boundary, and says the database role's permissions are the effective limit. Its [Postgres MCP server docs](https://awslabs.github.io/mcp/servers/postgres-mcp-server) describe the SQL guard as best-effort, defense in depth. So:

- **The user creates the role, not you.** Give them [setup/pg-audit-role.sql](setup/pg-audit-role.sql) or [setup/mysql-audit-role.sql](setup/mysql-audit-role.sql) to run as an administrator. Never run them yourself and never ask for admin credentials. The role setup is:
  - **PostgreSQL:** `pg_monitor` (settings and statistics, no table data), plus `default_transaction_read_only`, `statement_timeout`, `lock_timeout` and `idle_in_transaction_session_timeout` set on the role. `pg_read_all_data` is optional and only with the user's consent. Never `pg_write_all_data`, `pg_maintain`, `pg_signal_backend`, or the server file and program roles: [predefined roles](https://www.postgresql.org/docs/current/predefined-roles.html) warns these can grant superuser-level access.
  - **MySQL:** `PROCESS`, `SELECT` on `performance_schema`, and `SELECT, EXECUTE` on `sys` ([sys schema prerequisites](https://dev.mysql.com/doc/refman/8.4/en/sys-schema-prerequisites.html)). Each session then sets `transaction_read_only`, `max_execution_time` and `lock_wait_timeout`. Never `FILE` or `SUPER`.
- **Check the session before anything else** with `queries/<engine>/00-session.sql`. Stop and point the user to the setup file if:
  - the role is a superuser,
  - any risky role or privilege row comes back,
  - `writable_tables` > 0,
  - or `transaction_read_only` is off.

  Do not "continue carefully". A role with `CREATE` on a schema or database is a warning, not a stop, because the read-only transaction blocks DDL. `default_transaction_read_only` is only a default that a session can turn off ([client settings](https://www.postgresql.org/docs/current/runtime-config-client.html)). That is why the absence of write grants is the real boundary.
- **Prefer a read replica.** Confirm it with `on_replica` (Postgres `pg_is_in_recovery()`) or `read_only`/`super_read_only` (MySQL). Statistics are per instance, so usage-based findings must be checked on every instance (see Steps).
- **Run only the files in `queries/`, as written,** one session, in order. Never run any of these:
  - writes or DDL;
  - maintenance: `VACUUM`, `ANALYZE`, `REINDEX`, `OPTIMIZE TABLE`, `ANALYZE TABLE`;
  - server settings: `SET GLOBAL`;
  - extension installs: `CREATE EXTENSION`;
  - session control: `pg_cancel_backend`, `pg_terminate_backend`, `KILL`, or the `sql_kill_*` text the sys views offer;
  - statistics resets: `pg_stat_statements_reset()`, `pg_stat_reset()`, `FLUSH`. A reset destroys the user's history.

  `EXPLAIN ANALYZE` belongs to `/db-skills:db-explain`, with consent. When a finding needs one of these, it becomes a step in the report for the user.
- **Redact before you show.**
  - pg_stat_statements replaces constants with `$1`, but its [docs](https://www.postgresql.org/docs/current/pgstatstatements.html) warn that texts can show literal values when many entries are being deallocated. Report `pg_stat_statements_info.dealloc`.
  - `pg_stat_activity.query` and MySQL `processlist.INFO` are raw.
  - The query files replace quoted strings and numbers with `?`. Before you print any text, still read it for emails, tokens or names in identifiers and comments, and cut them.
  - Never select `QUERY_SAMPLE_TEXT`, `pg_stats.most_common_vals`/`histogram_bounds` or `SHOW ENGINE INNODB STATUS`: they carry real values.
- **Respect the timeouts.** If a query hits the 5 s timeout, record "not checked: timed out" and move on. Do not raise a timeout without asking.

## Steps

1. **Connect.** Ask which environment variable or secret holds the connection string for the audit role. Never ask the user to paste a password into the chat. Detect the engine from the URL or from `SELECT version()`.
2. **Guard.** Run `queries/pg/00-session.sql` or `queries/mysql/00-session.sql` and apply the stop rules from Safety.
3. **Context.** Run `01-version-settings.sql` and record:
   - the version (`server_version_num` or `VERSION()`) and whether this is a replica;
   - the statistics window: time since `stats_reset`, server start, or `Uptime` (MySQL);
   - the extensions present.

   Mark every usage-based finding (top statements, unused indexes, sequential scans, cache hit) **provisional** when the window is under 7 days. Never propose dropping an index on a window shorter than one full business cycle, at least 30 days including month-end jobs. Both thresholds are this skill's, not an official number.
4. **Collect.** Run the remaining files in order:
   - Postgres: `02` to `11`, plus `12-vacuum-time-pg18.sql` only when `server_version_num` >= 180000.
   - MySQL: `02` to `10`.

   If `pg_stat_statements` is not installed, or `performance_schema` is OFF, skip that file and report the gap as a finding (pg-observability, or the MySQL observability skill).
5. **Interpret** with the table below. The thresholds are this skill's triage defaults; the fix comes from the decision skill named. MySQL decision skills arrive in v1.1: until then, name the topic ("MySQL indexing skill", "MySQL online DDL skill") and cite the MySQL manual page.

   | Check | PG file | MySQL file | Flag when | Severity | Decision skill |
   |---|---|---|---|---|---|
   | Top statements | 02 | 02 | one statement ≥ 20% of total time, or rows examined per row sent ≥ 100 | HIGH | pg-query-patterns, pg-indexing; hand the statement to `/db-skills:db-explain` |
   | Cache / buffer pool hit | 03 | 03 | below 95% on an OLTP workload, after a window of at least a day | MEDIUM | pg-config-by-size |
   | Unused indexes | 04 | 04 | 0 scans over a window ≥ 30 days on **every** instance | MEDIUM above 1 GB, else LOW | pg-indexing |
   | Duplicate or prefix-redundant | 05 | 05 | any | MEDIUM above 1 GB, else LOW | pg-indexing |
   | Invalid index | 05 | n/a | any | MEDIUM | pg-online-migrations |
   | FK without index | 06 | n/a | any, when parent rows are deleted or their keys updated | HIGH if the child is large, else MEDIUM | pg-indexing |
   | Heavy sequential / full scans | 07 | 06 | large table with avg rows per scan near the table size, many times a day | HIGH or MEDIUM | pg-indexing, pg-query-patterns |
   | Dead tuples, autovacuum lag | 08 | n/a | `n_dead_tup` above `vacuum_trigger` with an old or empty `last_autovacuum`; `dead_pct` ≥ 20% | MEDIUM | pg-vacuum-and-bloat |
   | XID age | 08 | n/a | `pct_of_freeze_max_age` ≥ 100 is HIGH; `xid_age` ≥ 1.5 billion is CRITICAL | HIGH / CRITICAL | pg-vacuum-and-bloat |
   | History list length | n/a | 07 | growing with an old transaction open | HIGH | MySQL transactions skill |
   | Long or idle-in-transaction sessions | 09 | 08 | idle in transaction ≥ 5 min, or a session holding the oldest xmin | HIGH | pg-transactions-and-locking |
   | Replication slots | 09 | n/a | inactive slot retaining WAL or holding xmin | CRITICAL if it is growing | pg-vacuum-and-bloat |
   | Lock waits | 10 | 09 | any blocking chain; a DDL waiting on a metadata lock | CRITICAL for a chain, else HIGH | pg-transactions-and-locking, pg-online-migrations |
   | Connections | 11 | 10 | ≥ 90% of `max_connections` is CRITICAL, ≥ 80% is HIGH | CRITICAL / HIGH | pg-connections; run `/db-skills:db-connection-budget` |
   | Settings | 01 | 01 | no `statement_timeout`/`idle_in_transaction_session_timeout` for app roles, `track_io_timing` off, defaults on a large instance | LOW | pg-config-by-size, pg-observability |

   Facts behind the checks, from official docs:
   - Postgres does not index foreign-key referencing columns, so deleting or updating a parent row scans the child table ([constraints](https://www.postgresql.org/docs/current/ddl-constraints.html)).
   - InnoDB creates an index for each foreign key itself, so MySQL has no missing-FK check ([FOREIGN KEY constraints](https://dev.mysql.com/doc/refman/8.4/en/create-table-foreign-keys.html)).
   - Postgres forces an anti-wraparound vacuum at `autovacuum_freeze_max_age`, and the server stops assigning XIDs as unfrozen age nears 2^31 ([routine vacuuming](https://www.postgresql.org/docs/current/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND)).
   - Open read views block purge and grow the history list ([purge configuration](https://dev.mysql.com/doc/refman/8.4/en/innodb-purge-configuration.html)).
   - `sys.schema_unused_indexes` counts from server start, and every sys index view reads only tables the account has a privilege on ([sys views](https://dev.mysql.com/doc/refman/8.4/en/sys-schema-views.html)). With no `SELECT` on the app schema, report "index checks: app schema not visible".
6. **Cross-check usage findings.** Before you propose dropping an index or calling a table "scanned", ask the user to run `04`/`07` (`04`/`06` on MySQL) on each replica with the same role. A replica serves its own reads and keeps its own counters.
7. **Write the fixes as migrations.**
   - **Match the format.** Detect the repo's migration tool (Rails, Django, Alembic, Flyway, Liquibase, Prisma, golang-migrate, Knex, plain SQL) and use its file format. Show the files in the report, and create them only if the user asks. Never run them.
   - **Postgres, new index:**

     ```sql
     SET lock_timeout = '5s';
     CREATE INDEX CONCURRENTLY IF NOT EXISTS ... ;
     ```

     `CONCURRENTLY` cannot run inside a transaction, so turn off the tool's per-migration transaction. Rollback: `DROP INDEX CONCURRENTLY IF EXISTS ...`. A failed build leaves an INVALID index ([CREATE INDEX](https://www.postgresql.org/docs/current/sql-createindex.html)).
   - **Postgres, drop an index:** `DROP INDEX CONCURRENTLY`. Rollback: the definition from `pg_get_indexdef`, built `CONCURRENTLY`. Note how long the rebuild takes.
   - **MySQL, new index:** `ALTER TABLE t ADD INDEX ix (...), ALGORITHM=INPLACE, LOCK=NONE` after `SET SESSION lock_wait_timeout = 5`. Rollback: `ALTER TABLE t DROP INDEX ix`. Asking for an algorithm or lock level the server cannot honor makes it fail instead of blocking writes ([online DDL](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-operations.html)).
   - **MySQL, drop an index:** first `ALTER TABLE t ALTER INDEX ix INVISIBLE` (rollback: `VISIBLE`). Ship the `DROP INDEX` as a later migration, after a business cycle with no regressions ([invisible indexes](https://dev.mysql.com/doc/refman/8.4/en/invisible-indexes.html)).
   - **Postgres, per-table autovacuum or role timeouts:** for example `ALTER TABLE ... SET (autovacuum_vacuum_scale_factor = ...)` or `ALTER ROLE app SET idle_in_transaction_session_timeout = ...`. Rollback with `RESET (...)` or `ALTER ROLE app RESET ...`. Take the values from the decision skill.
   - **Server parameters** (`shared_buffers`, `max_connections`, `innodb_buffer_pool_size`) are not migrations. List them as parameter-group or config changes, and say whether they need a restart.
   - **One-off maintenance** the user may choose to run, such as `ANALYZE` of a table with stale statistics or dropping an inactive slot: list it as an operator step with its lock and I/O cost. Never run it.
8. **Report** in the format below. Write it to a Markdown file in the repo only if the user asks.

## Output

Start with a header:

```
Database audit: <engine> <version> on <host alias, never the full URL>, <primary|replica>
Stats window: <since> (<n> days)   pg_stat_statements dealloc: <n>   Checked replicas: <list or "none">
Not checked: <files skipped and why: extension missing, timed out, schema not visible>
```

Then one table, ordered by severity, then by estimated impact (share of DB time, size, rows):

| # | Severity | Finding | Evidence | Related skill | Proposed migration (rollback) | How to verify |
|---|---|---|---|---|---|---|
| F1 | HIGH | `orders` has no index for FK `orders_customer_id_fkey` | 8.4 GB table, `customers` deletes 1.2k/day, top statement 31% of DB time is `DELETE FROM customers WHERE id = $1` | pg-indexing | `20261018_orders_customer_id_idx.sql`: `CREATE INDEX CONCURRENTLY orders_customer_id_idx ON orders (customer_id)` (rollback `DROP INDEX CONCURRENTLY orders_customer_id_idx`) | `indisvalid` true; plain `EXPLAIN` of the FK check shows an Index Scan; `mean_exec_time` of the delete drops after 24 h |

The row above is an example of the format.

Severity:
- **CRITICAL:** risk of an outage soon, such as wraparound, connection exhaustion, a blocking chain, or a slot filling the disk.
- **HIGH:** a large share of DB time or lock time with a clear fix.
- **MEDIUM:** waste with a measurable cost, such as large unused or duplicate indexes, low hit ratio, or vacuum lag.
- **LOW:** hygiene and configuration drift.

After the table, give each migration in full (file name, up, down, the lock it takes, expected duration) and the operator steps that are not migrations. Query texts appear only redacted. End with what the user should rerun to confirm, and when.

## When not to use

- One query is slow and the user knows which one: use `/db-skills:db-explain`.
- The question is how many connections the fleet may open: use `/db-skills:db-connection-budget`.
- The only credentials available are a superuser, master or owner account, and the user will not create the audit role: do not connect. Hand over the setup file and stop.
- Statistics were just reset or the server just restarted: usage counters are empty. Run only the structural checks (`00`, `01`, `05`, `06`, `08`, `11`) and suggest a full audit after a business cycle.
- Reviewing a schema or migration that has not been deployed yet: use the decision skills (pg-indexing, pg-online-migrations, pg-keys-and-types) on the code instead.
- Engines other than PostgreSQL 15+ and MySQL 8.4+ (MariaDB, older majors): the queries are not tested there.
