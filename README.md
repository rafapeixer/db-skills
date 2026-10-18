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

### Workflows: your database, read-only

| Workflow | What you get |
|---|---|
| [db-audit](skills/db-audit/SKILL.md) | A read-only health check of your PostgreSQL or MySQL database: top statements, cache hit, unused, duplicate and missing indexes, vacuum or purge lag, long transactions, lock waits and connections, ranked by impact, with migrations and rollbacks |
| [db-explain](skills/db-explain/SKILL.md) | The plan of one slow SELECT explained in plain words, and the index or rewrite that fixes it, as a migration; EXPLAIN ANALYZE only with your consent |
| [db-connection-budget](skills/db-connection-budget/SKILL.md) | How many connections your fleet opens at its worst moment (autoscaling plus deploy surge) against what the database allows, with pool sizes and per-role caps |

### Next

- **MySQL (v1.1):** keys and InnoDB layout, indexing, query patterns, transactions and isolation, online DDL, connections.

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
