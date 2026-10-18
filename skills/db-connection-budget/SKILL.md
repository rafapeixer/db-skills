---
name: db-connection-budget
description: Use when the user asks how many database connections their fleet may open, how big each pool should be, whether a scale-up or deploy will exhaust max_connections, or why they see "too many connections" on PostgreSQL or MySQL, including RDS and Aurora. Read-only: reads max_connections, reserved slots and current connections per user and application, combines them with replicas, workers, pool sizes and deploy surge, and proposes pool sizes and per-role caps without applying them.
disable-model-invocation: true
argument-hint: "[env var holding the connection string] [services: replicas x processes x pool, deploy surge]"
metadata:
  verified: 2026-10-18
---

# Connection budget

## Purpose

The user gets a budget: how many connections the database really has for applications, how many the fleet can open at its worst moment, and the headroom left. The worst moment is maximum autoscaling plus a rolling deploy plus workers and cron jobs. Then come the pool size per process and the caps that keep one service from starving the others, written as config changes and migrations to review. Exhausting connections takes every service down at once, and adding connections does not add throughput. In the [go-skills benchmark](https://github.com/rafapeixer/go-skills/blob/main/BENCHMARKS.md), the same 10,000 req/s against Postgres needed:

| Fleet at 10,000 req/s | Connections |
|---|---|
| Go | 16 |
| Java | 40 |
| Python | 96, above the 80 the db.t4g.micro allowed |

## Safety

- **Read-only is enforced by the database role.** Connect with the role from `skills/db-audit/setup/pg-audit-role.sql` or `skills/db-audit/setup/mysql-audit-role.sql`, which the user creates and you never run.
  - **Privileges:** this workflow needs no table data. `pg_monitor`, or `PROCESS` plus `performance_schema`, is enough.
  - **Why the role:** do not rely on an MCP server's read-only mode. AWS's own servers had read-only bypasses in 2026 ([CVE-2026-87911](https://github.com/awslabs/mcp/security/advisories/GHSA-fph8-pg5w-78fv), [CVE-2026-85788](https://github.com/awslabs/mcp/security/advisories/GHSA-x25m-ph3m-3r9q)), and AWS says the database role's permissions are the effective limit.
- **Run `queries/<engine>/00-session.sql` first.** Stop under the same conditions as `/db-skills:db-audit`: superuser, a risky role or privilege, writable tables, or a session that is not read-only.
- **Your own session counts.** It takes one of the slots you are measuring. Use one connection and close it when done. The setup file caps the role at 3.
- **Never change connection settings or sessions.** Never run `SET GLOBAL max_connections`, `ALTER SYSTEM`, `ALTER ROLE` or `ALTER USER`, and never end idle sessions (`pg_terminate_backend`, `KILL`). All of these go in the report for the user to apply.
- **Keep client details out of the report.** Client addresses, host names and application names can identify people or internal systems. The query files count client hosts instead of listing them. Name applications only as the user's own services.

## Steps

1. **Guard.** Run `00-session.sql`. Note the engine, the version, and whether this is a replica: each read replica has its own `max_connections` and needs its own budget.
2. **Read the limits** with `01-limits.sql`.
   - **PostgreSQL:** usable slots are `max_connections − superuser_reserved_connections − reserved_connections`. `reserved_connections` exists on 16+ and is kept for `pg_use_reserved_connections` members ([predefined roles](https://www.postgresql.org/docs/current/predefined-roles.html)). Each connection is a separate server process ([architecture](https://www.postgresql.org/docs/current/tutorial-arch.html)), so slots also cost memory.
   - **MySQL:** usable slots are `max_connections`. The manual keeps one extra connection for an account with `CONNECTION_ADMIN` (or `SUPER`) so an administrator can still get in ([too many connections](https://dev.mysql.com/doc/refman/8.4/en/too-many-connections.html)). `Max_used_connections` is the server's own peak since `Uptime` began.
   - **Existing caps:** record any per-role (`rolconnlimit`), per-database or per-account (`max_user_connections`) limits.
3. **Read current use** with `02-current-connections.sql`, per user and application. That shows who holds slots, how many sit idle (pool slots kept open) and how many sit idle in transaction. Postgres keeps no peak counter, so ask for the peak from the user's monitoring, for example the `DatabaseConnections` metric on RDS.
4. **Get the fleet's worst case.**
   - **Read the repo first:**
     - Kubernetes manifests and Helm values: `replicas`, HPA `maxReplicas`, `strategy.rollingUpdate.maxSurge`;
     - compose `deploy.replicas`;
     - process counts: gunicorn or uvicorn `workers`, puma `workers` × `threads`, Node cluster size;
     - pool settings: HikariCP `maximumPoolSize`, pgx `pool_max_conns`, SQLAlchemy `pool_size` + `max_overflow`, Prisma `connection_limit`, `DATABASE_POOL_SIZE`;
     - workers and jobs: Sidekiq or Celery concurrency, cron jobs, migration jobs;
     - serverless: Lambda reserved concurrency (each instance opens its own pool).
   - **Then ask the user** to confirm or fill in, for every service: maximum replicas, deploy surge, processes per replica, and pool maximum per process (with overflow).
   - **Surge:** in Kubernetes Deployments, `maxSurge` defaults to 25% ([Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#max-surge)). Blue-green deploys double the fleet for a moment.
5. **Compute:**

   ```
   usable        = max_connections − reserved slots                  (step 2)
   service_peak  = (max_replicas + surge) × processes_per_replica × (pool_max + overflow)
   overhead      = admin + monitoring + this audit + migrations + cron (from step 3 and the user)
   demand        = Σ service_peak + overhead
   headroom      = usable − demand
   target        demand ≤ 80% of usable   (this skill's margin for failover reconnect storms and one-off jobs)
   pool_max      ≤ floor((0.8 × usable − overhead) / Σ ((max_replicas + surge) × processes_per_replica))
   ```

   - **With a pooler**, budget both sides:
     - Client side: the fleet's demand must stay under PgBouncer `max_client_conn`.
     - Server side: `default_pool_size` applies per user and database pair ([PgBouncer config](https://www.pgbouncer.org/config.html)). Server connections = pool size × pairs × PgBouncer instances, and that must fit in `usable`.
   - **On RDS:** if the user has not set `max_connections`, the default comes from the instance memory ([RDS quotas](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html#RDS_Limits.MaxConnections)). `DBInstanceClassMemory` is what is left after the OS and RDS reserve memory, so the real value is lower than the class's memory suggests.
     - PostgreSQL: `LEAST({DBInstanceClassMemory/9531392}, 5000)`.
     - MySQL: `{DBInstanceClassMemory/12582880}`. AWS gives about 630 for an 8 GiB class and about 60 for a db.t3.micro.

     The same page warns that a value set too high can leave the instance in `incompatible-parameters` status. It recommends RDS Proxy for applications that open and close connections often or keep many long-lived ones.
   - **Compare with the benchmark:** in the [go-skills benchmark](https://github.com/rafapeixer/go-skills/blob/main/BENCHMARKS.md), Java and Python fleets reached 65 of 80 connections with 8 replicas, so two more replicas during a deploy would exceed the limit. If the budget fails, shrink pools before raising `max_connections`: a pool larger than the work the database can run at once only queues inside the database.
6. **Propose changes.**
   - **Pool sizes:** a diff to the app config for each service.
   - **Postgres caps:** per-role caps so one service cannot take every slot: `ALTER ROLE app_api CONNECTION LIMIT 40;` (rollback `ALTER ROLE app_api CONNECTION LIMIT -1;`).
   - **MySQL caps:** `ALTER USER 'app_api'@'%' WITH MAX_USER_CONNECTIONS 40;` (rollback `... WITH MAX_USER_CONNECTIONS 0;`).
   - **Idle in transaction:** if 02 shows connections sitting idle in transaction, a role timeout is the fix, explained in pg-transactions-and-locking.
   - **Changing `max_connections` or adding a pooler:** these are infrastructure changes, not migrations. `max_connections` is static and needs a restart (on RDS: a custom parameter group and a reboot). Explain the trade-off with pg-connections and pg-config-by-size, or the MySQL connections skill (v1.1).
   - **Files:** use the repo's migration tool format for the SQL. Show everything in the report, and create files only if the user asks.
7. **Report** in the format below.

## Output

```
Connection budget: <engine version> on <host alias>, <primary|replica>
max_connections <n> − reserved <n> = usable <n>   peak seen <n> (<source>)   now <n> (<idle> idle, <idle_tx> idle in tx)
```

Budget table, one row per service plus overhead:

| Service | Max replicas | Surge | Processes / replica | Pool max (+ overflow) | Peak connections |
|---|---|---|---|---|---|
| api | 10 | +3 (25%) | 1 | 8 | 104 |
| worker | 4 | +1 | 2 | 5 | 50 |
| overhead (admin, monitoring, migrations, cron) | | | | | 10 |
| **demand** | | | | | **164 of 189 usable (87%): over the 80% target** |

The row values above are an example of the format.

Then findings, ordered by impact:

| # | Severity | Finding | Evidence | Related skill | Proposed change (rollback) | How to verify |
|---|---|---|---|---|---|---|

Severity:
- **CRITICAL:** demand above usable, or refused connections already counted in `Connection_errors_max_connections` or in the logs.
- **HIGH:** demand above 80% of usable, or a single service able to take every slot.
- **MEDIUM:** large idle pools, or idle-in-transaction slots.
- **LOW:** caps and timeouts missing.

Verification is the same query rerun after the change: peak connections during the next deploy stay under the target, and no refused connections. End with the assumptions the user confirmed, since the budget is only as good as those numbers. Write the report to a Markdown file in the repo only if the user asks.

## When not to use

- The user wants the driver-level pool settings themselves (timeouts, lifetimes, health checks for pgx, HikariCP, asyncpg): those belong to the language skill repositories, such as [go-skills](https://github.com/rafapeixer/go-skills).
- Connections are fine but queries are slow: use `/db-skills:db-audit` or `/db-skills:db-explain`.
- The user is choosing an instance size or `max_connections` for a database that does not exist yet: use the pg-connections and pg-config-by-size decision skills. There is nothing live to measure.
- The application reaches the database only through a managed proxy whose server-side limits you cannot read (RDS Proxy, a hosted PgBouncer): read the proxy's own settings and metrics first. This workflow sees only the backend connections.
