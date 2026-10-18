# db-skills

**English** | [Português](README.pt-BR.md)

**Opinionated PostgreSQL and MySQL skills for coding agents, plus read-only workflows that audit your own database.**

Coding agents write SQL that works on a laptop and falls over in production: one query per row, `OFFSET` pagination over millions of rows, a migration that locks the table for minutes, a fleet that opens more connections than the database allows. The database is often the biggest line on the bill, and these mistakes are where the money goes.

Each skill covers **one decision**, takes a position, and proves it with examples that **run against real PostgreSQL and MySQL in CI**: the good example asserts the plan uses the index, the bad example asserts the sequential scan it causes. Workflow skills go further and look at **your** database, read-only, and hand you a report with the migrations to fix it.

Works with Claude Code, Cursor, Codex and any agent that reads `SKILL.md` files, in any application language.

---

## Install

### Claude Code plugin (recommended)

```
/plugin marketplace add rafapeixer/db-skills
/plugin install db-skills@db-skills
```

Decision skills load automatically when the task matches. Workflows run on request:

```
/db-skills:db-audit
/db-skills:db-explain
/db-skills:db-connection-budget
```

### Other agents

```bash
npx skills add rafapeixer/db-skills
```

Or copy `skills/` into wherever your agent loads skills from.

---

## Skills

### PostgreSQL (v1)

| Skill | Use when |
|---|---|
| [pg-keys-and-types](skills/pg-keys-and-types/SKILL.md) | Choosing primary keys and column types: bigint identity, uuidv7 (PG 18+), timestamptz, text with CHECK, numeric for money, NOT NULL, CHECK and FK constraints, jsonb only for schemaless data |
| [pg-indexing](skills/pg-indexing/SKILL.md) | Deciding which indexes to create and drop: composite order, covering INCLUDE, partial and expression indexes, foreign key indexes, duplicates and unused indexes, skip scan (PG 18+) |
| [pg-query-patterns](skills/pg-query-patterns/SKILL.md) | Shaping queries: one statement per page with LEFT JOIN LATERAL instead of N+1, keyset instead of OFFSET, batch writes with unnest or COPY, ON CONFLICT upserts, RETURNING, named columns |
| [pg-transactions-and-locking](skills/pg-transactions-and-locking/SKILL.md) | Scoping transactions and locks: short transactions, isolation with whole-transaction retry on 40001, SKIP LOCKED queues, NOWAIT and lock_timeout, per-role timeouts, advisory locks behind poolers |
| [pg-online-migrations](skills/pg-online-migrations/SKILL.md) | Changing a live table without blocking: lock_timeout with retries, the lock each ALTER TABLE takes, constant defaults, NOT VALID then VALIDATE, NOT NULL without a scan, CREATE INDEX CONCURRENTLY, expand/contract |
| [pg-connections](skills/pg-connections/SKILL.md) | Sizing a fleet's connections: budget from max_connections minus reserved, replicas × processes × pool including deploy surge, per-role CONNECTION LIMIT, PgBouncer or RDS Proxy |
| [pg-observability](skills/pg-observability/SKILL.md) | Finding the queries that cost the most: pg_stat_statements by total time, track_io_timing, slow-query log, sampled auto_explain, safe EXPLAIN ANALYZE, wait events, pg_stat_io, RDS Database Insights |
| [pg-config-by-size](skills/pg-config-by-size/SKILL.md) | Sizing shared_buffers, effective_cache_size, work_mem and maintenance_work_mem from the instance, raising work_mem for one query, RDS and Aurora parameter groups, PG 18 async I/O |
| [pg-vacuum-and-bloat](skills/pg-vacuum-and-bloat/SKILL.md) | Keeping tables from bloating: autovacuum tuned per hot table, no long or idle-in-transaction sessions, HOT updates with fillfactor, batched deletes, no VACUUM FULL on live tables, XID wraparound |
| [pg-throughput-per-connection](skills/pg-throughput-per-connection/SKILL.md) | Getting more throughput per connection, too many connections, slow under load, lock waits, scaling without a bigger instance: one statement per request, commit before non-database work, SKIP LOCKED queues, sharded hot counters, a small measured pool |

### Workflows: your database, read-only

| Workflow | What you get |
|---|---|
| [db-audit](skills/db-audit/SKILL.md) | A read-only health check of your PostgreSQL or MySQL database: top statements, cache hit, unused, duplicate and missing indexes, vacuum or purge lag, long transactions, lock waits and connections, ranked by impact, with migrations and rollbacks |
| [db-explain](skills/db-explain/SKILL.md) | The plan of one slow SELECT explained in plain words, and the index or rewrite that fixes it, as a migration; EXPLAIN ANALYZE only with your consent |
| [db-connection-budget](skills/db-connection-budget/SKILL.md) | How many connections your fleet opens at its worst moment (autoscaling plus deploy surge) against what the database allows, with pool sizes and per-role caps |

### MySQL (v1.1)

| Skill | Use when |
|---|---|
| [mysql-keys-and-types](skills/mysql-keys-and-types/SKILL.md) | Choosing InnoDB primary keys and column types: BIGINT AUTO_INCREMENT vs BINARY(16) UUIDs, utf8mb4, DATETIME vs TIMESTAMP, DECIMAL money, strict mode, NOT NULL, CHECK and foreign keys, JSON |
| [mysql-indexing](skills/mysql-indexing/SKILL.md) | Adding, reviewing or removing InnoDB indexes, or EXPLAIN shows type ALL, Using filesort or index_merge you did not expect |
| [mysql-query-patterns](skills/mysql-query-patterns/SKILL.md) | Loading a page with its children, paginating (keyset written out, not a row constructor), batch inserts, upserts with the AS alias, named columns, safe EXPLAIN ANALYZE |
| [mysql-transactions-and-locking](skills/mysql-transactions-and-locking/SKILL.md) | Opening InnoDB transactions, REPEATABLE READ vs READ COMMITTED and gap locks, SKIP LOCKED queues, NOWAIT, lock wait timeouts (1205) and deadlocks (1213) |
| [mysql-online-ddl](skills/mysql-online-ddl/SKILL.md) | Changing a schema under live traffic: explicit ALGORITHM and LOCK, INSTANT row-version limits, metadata locks with lock_wait_timeout, invisible indexes before a drop, gh-ost |
| [mysql-connections](skills/mysql-connections/SKILL.md) | Sizing a fleet's connection pools: the budget, deploy surge, per-account MAX_USER_CONNECTIONS, wait_timeout vs pool lifetime, RDS Proxy pinning |

---

## More volume, fewer connections, no lock waits

The same four API requests written the usual way and the way these skills teach, measured with `pgbench` against PostgreSQL 17 limited to 2 vCPU and 1 GiB (an RDS db.t4g.micro) with 0.5 ms of network latency ([`benchmarks/throughput/`](benchmarks/throughput/)):

| Request | Usual way, best case | With the skills, 4 connections | With the skills, best case | Latency |
|---|---|---|---|---|
| Page of orders with items | 2,179 req/s (16 connections) | **5,893 req/s** | **15,047 req/s (6.9×)** | 6.9 ms → **0.68 ms** |
| Create an order with items | 3,279 req/s (16) | 2,405 req/s | **8,464 req/s (2.6×)** | 4.3 ms → **1.7 ms** |
| Claim a queued job | ~335 req/s at any pool size, 40 of 64 sessions waiting on locks | **1,656 req/s** | **4,994 req/s (15×)**, no lock waits | 47 ms → **3.2 ms** |
| Decrement a hot counter | 1,671 req/s, worse with more connections | **2,372 req/s** | **6,681 req/s (4×)** | 11 ms → **2.4 ms** |

With 4 connections the one-statement page serves 3.2 times what the N+1 page serves with 64. On this instance, 64 connections gave less throughput than 16 in every case: a small pool with short holds beats a big one. The rules are in [pg-throughput-per-connection](skills/pg-throughput-per-connection/SKILL.md).

---

## Does it change what agents write?

Measured with `claude plugin eval` ([`evals/`](evals/)): each task runs with and without the plugin, 3 times per side, and regex graders check the SQL file the agent writes. October 2026.

| | Without plugin | With plugin |
|---|---|---|
| 8 core tasks (online index, FK, NOT NULL, pagination in both engines, MySQL INSTANT column, UUID key, job queue) | 24 / 24 | **24 / 24** |
| 9 tasks with known traps | 23 / 27 | **27 / 27** |
| **All 51 runs** | **47 / 51 (92%)** | **51 / 51 (100%)** |

Where the agent failed without the plugin:

| Task | Without | With | The failure |
|---|---|---|---|
| Money transfer procedure on MySQL | 1 / 3 | **3 / 3** | No retry of the whole transaction on deadlock 1213, so a concurrent transfer loses money |
| Singleton job behind PgBouncer | 1 / 3 | **3 / 3** | Session-level `pg_advisory_lock` behind transaction pooling, so the "single" job runs twice |

**Auditing a real database.** [`benchmarks/audit-fixture/`](benchmarks/audit-fixture/) builds a PostgreSQL 17 database with ten planted problems (unindexed foreign key, duplicate and unused indexes, OFFSET pagination, N+1, a session idle in transaction, autovacuum off with dead rows, a fleet over the connection budget, a dangerous global `work_mem`, random UUID keys), runs traffic and exports the standard statistics views. The agent reads the export and writes a report and a migration; one judge per problem plus SQL safety checks (CONCURRENTLY, no VACUUM FULL, no dropped primary keys).

| | Without plugin | With plugin |
|---|---|---|
| Runs that found all ten problems and wrote a safe migration | 1 / 3 | **3 / 3** |
| Checks passed | 45 / 48 | **48 / 48** |

Without the plugin the agent missed the OFFSET pagination, the most expensive statement in the export, in 2 of 3 runs, and the global `work_mem` in 1.

The model already knows most textbook rules; the plugin makes it right every time and closes the gaps that cause production incidents. An earlier round, before the skill descriptions named the key rule and the user's words ("infinite scroll", "next page"), showed no difference and one skill that never loaded; that is why every description now starts with the task and its most important rule.

---

## Safety of the workflows

The workflows connect to your database, so their safety is enforced by the database, not by promises:

- They ask you to create a **read-only role** with statement and lock timeouts (scripts included). The database refuses any write, even if a query slipped through.
- They run only the queries shipped in `skills/db-*/queries/`, which CI checks contain no writes, DDL, maintenance commands or `EXPLAIN ANALYZE`.
- They never apply a fix. Every change comes back as a migration file for you to review.
- Query texts are shown with literals redacted.

---

## Principles

- **One decision per skill**, with a reason and, where possible, a number.
- **Official sources only:** postgresql.org, dev.mysql.com and AWS documentation. Third-party claims are not used.
- **Examples run** against PostgreSQL 15 and 18 and MySQL 8.4 and 9.7 in CI.
- **Online first:** schema changes are shown the non-blocking way.
- **Vendor-neutral:** plain PostgreSQL and MySQL, with RDS and Aurora differences called out.

---

## Contributing

Disagree with a rule? Open an issue with the case where it breaks. Adding a skill? Start from [templates/](templates/), follow [CLAUDE.md](CLAUDE.md), one skill per PR. See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

MIT
