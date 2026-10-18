---
name: pg-connections
description: Use when sizing connection pools for an application fleet on PostgreSQL, choosing max_connections on RDS, adding replicas or worker processes, or deciding whether to put PgBouncer or RDS Proxy in front. Covers the connection budget formula, deploy surge, per-role CONNECTION LIMIT, transaction pooling limits and RDS Proxy pinning.
metadata:
  verified: 2026-10-18
---

# Connection budget and poolers

## The decision

How many connections your fleet opens to PostgreSQL, and when a pooler has to sit between the fleet and the server. It comes up every time you add replicas, switch to a multi-process server (gunicorn, uvicorn workers, Puma), raise a pool size, or pick a smaller instance. PostgreSQL forks one server process per connection, so connections are not free: each holds a slot out of `max_connections`, and memory, even when idle. Get the arithmetic wrong and the failure shows up at the worst moment, mid-deploy, when the new pods open their pools before the old ones close and get `sorry, too many clients already` (SQLSTATE 53300).

## The rule

1. Compute the budget from the server's settings: `max_connections − superuser_reserved_connections − reserved_connections` (PG 16+) minus a fixed reserve for admin, monitoring and migrations.
2. Compute the fleet peak as Σ over services of (replicas + deploy surge) × processes per replica × pool max, and keep it at or below the budget.
3. On RDS, read the real `max_connections` with `SHOW max_connections`, because the default `LEAST({DBInstanceClassMemory/9531392}, 5000)` is based on memory after OS and RDS reservations, below the nominal instance size.
4. Give every application role a `CONNECTION LIMIT` equal to its share of the budget, so a leaking pool fails at its own limit instead of starving everyone else.
5. When the fleet peak does not fit, put PgBouncer in transaction mode (1.21+, ideally 1.24+ where `max_prepared_statements=200` is the default) or RDS Proxy in front, instead of raising `max_connections`.
6. Behind a transaction pooler, never rely on session state: no session `SET`, `LISTEN`, session advisory locks, `WITH HOLD` cursors or session temp tables; use `SET LOCAL`, role settings or the proxy's initialization query.
7. Behind RDS Proxy, avoid what pins a session (`SET`, SQL `PREPARE`/`EXECUTE`, temp tables, `DECLARE` cursors, session advisory locks, `DISCARD ALL` reset queries, statements over 16 KB) and watch `DatabaseConnectionsCurrentlySessionPinned`.
8. Verify the formula against reality by counting connections per `application_name` in `pg_stat_activity`, and set `application_name` in every service's connection string.

## Why

**Every connection is a process.** "To achieve this it starts ("forks") a new process for each connection" ([architecture](https://www.postgresql.org/docs/18/tutorial-arch.html)). An idle connection is still a process and still a slot: the good example opens 3 idle connections and all 3 count. AWS says it plainly: "Database connections consume memory", and a value set too high can put the instance in **incompatible-parameters** status ([RDS quotas](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html#RDS_Limits.MaxConnections)).

**The budget is smaller than `max_connections`.** Once active connections reach `max_connections − superuser_reserved_connections` (default 3), only superusers get in; `reserved_connections` (PG 16+, default 0) holds back more slots for members of `pg_use_reserved_connections` ([connection settings](https://www.postgresql.org/docs/18/runtime-config-connection.html)). With the default 100 and 3 reserved, ordinary roles are refused at 97. Keep a few more for your own admin session, monitoring and the migration job, or you cannot get in to fix the outage.

**The process count and the surge are what people forget.** Pool size is per process, not per replica. In the [go-skills benchmark](https://github.com/rafapeixer/go-skills/blob/main/BENCHMARKS.md), serving the same 10,000 req/s:

| Fleet | Replicas | Pool per replica | Connections |
|---|---|---|---|
| Go | 2 | 8 | 16 |
| Java | 5 | 8 (fixed, always open) | 40 |
| Python | 12 | 2 workers × 4 | 96 |

The Python fleet no longer fits a db.t4g.micro's 80-connection budget, and that is before a rolling deploy adds replicas: with 3 surge replicas the bad example asks for 120. The pool size per process is a language decision; for Go see [go-skills: postgres-pgx-pool](https://github.com/rafapeixer/go-skills/blob/main/skills/postgres-pgx-pool/SKILL.md).

**RDS defaults are lower than the arithmetic suggests.** The PostgreSQL default is `LEAST({DBInstanceClassMemory/9531392}, 5000)`, allowed 6–262143, and `DBInstanceClassMemory` "automatically subtracts the amounts reserved to the operating system and the RDS processes" ([RDS quotas](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html#RDS_Limits.MaxConnections)). 1 GiB / 9531392 would give 112, so the real figure on a 1 GiB class is lower. Always read it from the server.

**A per-role limit contains the damage.** `CONNECTION LIMIT` caps concurrent connections for a login role; -1, the default, means no limit. It is enforced only approximately, it never applies to superusers, and prepared transactions and background workers are not counted ([CREATE ROLE](https://www.postgresql.org/docs/18/sql-createrole.html)). The good example opens 3 connections as `orders_app` with a limit of 3, and the fourth fails with SQLSTATE 53300 while the rest of the server keeps its slots.

**A pooler decouples clients from server processes.** PgBouncer in transaction mode lends a server connection only for the duration of a transaction, so hundreds of client connections share `default_pool_size` (default 20 per user/database pair) server connections ([PgBouncer config](https://www.pgbouncer.org/config.html)). The default `pool_mode` is `session`, which does not multiplex; set `transaction` explicitly. Protocol-level prepared statements work in transaction mode since 1.21.0 when `max_prepared_statements` is non-zero, and 1.24.0 made 200 the default ([changelog](https://www.pgbouncer.org/changelog.html)). Server connections = pool size × user/database pairs × PgBouncer instances; that product, not the client count, has to fit the budget.

**Transaction pooling breaks session state by design.** PgBouncer lists `SET/RESET`, `LISTEN`, `WITH HOLD` cursors, SQL `PREPARE`/`DEALLOCATE`, `PRESERVE/DELETE ROWS` temp tables, `LOAD` and session-level advisory locks as never supported in transaction mode; `NOTIFY`, `WITHOUT HOLD` cursors and `ON COMMIT DROP` temp tables work ([PgBouncer features](https://www.pgbouncer.org/features.html)). A session `SET statement_timeout` stays on the server connection and applies to whichever client gets it next.

**RDS Proxy stops multiplexing when it pins.** For PostgreSQL it pins on `SET` and `set_config`, `PREPARE`/`DISCARD`/`DEALLOCATE`/`EXECUTE`, temporary sequences, tables or views, declaring cursors, `LISTEN`, loading a module such as `auto_explain`, `nextval`/`setval`, `pg_advisory_lock` (transaction-level advisory locks do not pin), a `DISCARD ALL` reset query, and any statement over 16 KB. "For PostgreSQL setting a variable leads to session pinning": move identical `SET`s into the proxy's initialization query ([RDS Proxy pinning](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-pinning.html)). A fully pinned proxy is just one more hop in front of the same number of server processes.

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
SELECT current_setting('max_connections')::int AS max_connections,
current_setting('superuser_reserved_connections')::int AS superuser_reserved,
CASE WHEN current_setting('server_version_num')::int >= 160000
THEN current_setting('reserved_connections', true)::int
ELSE 0 END AS reserved,
5 AS admin_and_monitoring;

SELECT sum((replicas + surge) * processes * pool_max)::int AS peak_connections
FROM fleet;

ALTER ROLE orders_app CONNECTION LIMIT 3;
SELECT assert_error($$SELECT connect_as_orders_app('c4')$$, '53300',
'the fourth connection hits the role limit');
```

The test computes the budget from the server's own settings, gating `reserved_connections` on PG 16+ so the same query runs on PG 15 and 18. It sizes a fleet with the deploy surge included (33 connections) and asserts it fits. It caps `orders_app` at 3 connections, opens 3 with `dblink`, and asserts the fourth fails with 53300 (dblink wraps the server's error in 08001; a small function unwraps it). Last, it counts the 3 `orders-api` connections in `pg_stat_activity` and asserts all of them are idle, yet each holds a slot.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: the estimate multiplies replicas by pool and forgets the worker
-- processes: 12 * 4 = 48 looks comfortable on an 80-connection server.
SELECT assert_true((SELECT replicas * pool_max FROM fleet) = 48,
'the naive estimate says 48');

-- MISTAKE: the application role has no CONNECTION LIMIT (-1, the default),
-- so one leaking pool can take every non-reserved slot on the server,
-- starving every other service and the migrations job.
CREATE ROLE reports_app LOGIN;
```

The assertions describe the bad outcome: the real fleet needs 96 connections at steady state against 77 usable slots, 120 mid-deploy, and an unlimited role opens 6 idle connections with nothing to stop it. If the arithmetic or the default limit ever changes, the example fails.

## Checklist

When reviewing pool settings, deploy manifests or database settings under this skill, confirm:

- [ ] The budget uses `SHOW max_connections` from the real server, minus `superuser_reserved_connections`, `reserved_connections` (PG 16+) and an admin/monitoring reserve.
- [ ] The fleet peak multiplies replicas (at autoscaler max, plus deploy surge) × processes per replica × pool max, for every service, worker, cron and migration job.
- [ ] The fleet peak fits the budget; if it does not, the fix is a pooler or fewer, larger pools, not a higher `max_connections`.
- [ ] Every application login role has a `CONNECTION LIMIT`, and the limits add up to no more than the budget.
- [ ] Every service sets `application_name`, so `pg_stat_activity` shows who holds each connection.
- [ ] PgBouncer, if used, runs `pool_mode = transaction`, version 1.21+ with `max_prepared_statements` > 0, and pool size × user/database pairs × instances fits the budget.
- [ ] Code behind a transaction pooler uses no session `SET`, `LISTEN`, session advisory locks, `WITH HOLD` cursors or session temp tables.
- [ ] Behind RDS Proxy, session `SET`s live in the initialization query, there is no `DISCARD ALL` reset query, and `DatabaseConnectionsCurrentlySessionPinned` is monitored.

## When not to apply

- A single service with a handful of connections far below the budget: compute the budget once, set the role limit, and skip the pooler; it adds a hop and a failure point for nothing.
- Code that needs session state (`LISTEN` consumers, session advisory locks, long `WITH HOLD` cursors): give it a direct connection or a session-mode pool of its own, sized in the budget, and keep the transaction pooler for the request path.
- Superuser and replication connections: `CONNECTION LIMIT` never applies to superusers, so admin tooling is protected by `superuser_reserved_connections`, not by role limits; never run the application as a superuser.
- Aurora readers and RDS read replicas: each instance has its own `max_connections`; compute a separate budget per instance for the services that read from it.
