---
name: mysql-connections
description: Use when sizing MySQL connection pools, adding replicas or worker processes, setting max_connections, or seeing 'Too many connections'. Key rules: (replicas + deploy surge) x processes x pool max must fit max_connections minus an admin reserve (the RDS default is about 60 on a 1 GiB instance class); MAX_USER_CONNECTIONS per account; never give the application CONNECTION_ADMIN; pool max lifetime below wait_timeout; RDS Proxy pins sessions on SET, prepared statements and temporary tables.
metadata:
  verified: 2026-10-18
---

# Connection budget and per-account limits

## The decision

How many connections your fleet opens to MySQL, how each application account is capped, and when a proxy has to sit between the fleet and the server. It comes up every time you add replicas, switch to a multi-process server (gunicorn, uvicorn workers, Puma), raise a pool size, or pick a smaller instance. Community MySQL gives every client connection its own thread, so connections are not free: each holds a slot out of `max_connections` and memory, even when idle. Get the arithmetic wrong and the failure shows up mid-deploy, when the new pods open their pools before the old ones close and get `Too many connections`.

## The rule

1. Compute the budget as `max_connections` minus a fixed reserve for admin, monitoring and migrations; the one extra connection mysqld allows is for `CONNECTION_ADMIN` accounts only, so never count it for the application.
2. Compute the fleet peak as Σ over services of (replicas + deploy surge) × processes per replica × pool max, and keep it at or below the budget.
3. On RDS, read the real value with `SELECT @@GLOBAL.max_connections`, because the default `{DBInstanceClassMemory/12582880}` uses memory after OS and RDS reservations: about 60 on a db.t3.micro, not the 85 that 1 GiB suggests.
4. Create every application account `WITH MAX_USER_CONNECTIONS` equal to its share of the budget, and never grant it `CONNECTION_ADMIN` or `SUPER`.
5. Set the pool's max lifetime below `wait_timeout` (default 28800 s) and validate connections on borrow, instead of trusting sockets that sat idle for hours.
6. Verify the formula against reality with `Max_used_connections`, `Connection_errors_max_connections` and `Aborted_connects`, and count connections per account in `performance_schema.accounts`.
7. When the fleet peak does not fit, or clients are many and short-lived (Lambda, bursty jobs), put RDS Proxy in front instead of raising `max_connections`, and avoid what pins a session: user or system variable `SET`s outside the tracked list, prepared statements, temporary tables, `LOCK TABLES`, `GET_LOCK`, and statements over 16 KB.

## Why

**Every connection is a thread.** "Connection manager threads associate each client connection with a thread dedicated to it ... there are as many threads as there are clients currently connected, which has some disadvantages when server workload must scale to handle large numbers of connections" ([connection interfaces](https://dev.mysql.com/doc/refman/8.4/en/connection-interfaces.html)). The default `thread_handling` is `one-thread-per-connection` ([server system variables](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_thread_handling)). The alternative, the thread pool, "is an extension included in MySQL Enterprise Edition, a commercial product" ([thread pool](https://dev.mysql.com/doc/refman/8.4/en/thread-pool.html)); Community MySQL and RDS for MySQL do not have it, and Aurora MySQL lists `thread_handling` as not modifiable ([Aurora MySQL parameters](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Reference.ParameterGroups.html)). Plan for one thread per connection. AWS says it plainly: "Database connections consume memory", and a value set too high can put the instance in **incompatible-parameters** status ([RDS quotas](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html#RDS_Limits.MaxConnections)).

**The budget is `max_connections`, and the extra slot is not yours.** `max_connections` defaults to 151 on self-managed MySQL (range 1–100000), and the effective value is also capped by `open_files_limit − 810`. "mysqld actually permits max_connections + 1 client connections. The extra connection is reserved for use by accounts that have the CONNECTION_ADMIN privilege (or the deprecated SUPER privilege)" ([connection interfaces](https://dev.mysql.com/doc/refman/8.4/en/connection-interfaces.html), [too many connections](https://dev.mysql.com/doc/refman/8.4/en/too-many-connections.html)). That slot is how you get in during an outage; an application account with `CONNECTION_ADMIN` can take it too, which the bad example shows. Keep a few more for your own admin session, monitoring and the migration job.

**The process count and the surge are what people forget.** Pool size is per process, not per replica. In the [go-skills benchmark](https://github.com/rafapeixer/go-skills/blob/main/BENCHMARKS.md) (a PostgreSQL benchmark, but the arithmetic is the same on MySQL), serving the same 10,000 req/s:

| Fleet | Replicas | Pool per replica | Connections |
|---|---|---|---|
| Go | 2 | 8 | 16 |
| Python | 12 | 2 workers × 4 | 96 |

The Python fleet is already above a db.t3.micro's 60, and a rolling deploy adds more: with 3 surge replicas the bad example asks for 120. The pool size per process is a language decision; for Go see [go-skills](https://github.com/rafapeixer/go-skills).

**RDS defaults are lower than the arithmetic suggests.** The RDS for MySQL default is `{DBInstanceClassMemory/12582880}`, "effectively equivalent to MB/12", allowed 1–100000. `DBInstanceClassMemory` "automatically subtracts the amounts reserved to the operating system and the RDS processes": an 8 GiB db.m7g.large gets about 630 instead of 683, and a db.t3.micro gets about 60 ([RDS quotas](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html#RDS_Limits.MaxConnections)). Aurora MySQL uses a per-class table instead (for example 90 on db.t4g.medium, 1000 on db.r6g.large), and each instance has its own value ([Aurora MySQL max connections](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Managing.Performance.html#AuroraMySQL.Managing.MaxConnections)). Never hard-code the number; read it from the server.

**A per-account limit contains a leak.** `MAX_USER_CONNECTIONS` "restricts the maximum number of simultaneous connections to the server by each account"; with `0` (the default) the server falls back to the global `max_user_connections`, and "If max_user_connections is also zero, there is no limit for the account" ([CREATE USER](https://dev.mysql.com/doc/refman/8.4/en/create-user.html), [account resource limits](https://dev.mysql.com/doc/refman/8.4/en/user-resources.html)). Counting is per account, the `User` and `Host` row in `mysql.user`, not per client. A connection past the limit is refused with `ER_USER_LIMIT_REACHED` (error 1226). The examples check the stored limit in `mysql.user` and the effective limit with the global fallback; they cannot open a second login session from one SQL script, so the refusal itself is documented, not asserted.

**`wait_timeout` reclaims idle connections under your pool.** "The number of seconds the server waits for activity on a noninteractive connection before closing it", default 28800; interactive clients (`CLIENT_INTERACTIVE`) get `interactive_timeout`, also 28800 ([wait_timeout](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_wait_timeout)). A pool that never retires connections hands the next request a socket the server already closed. Retire connections before `wait_timeout` and before any proxy or load balancer idle timeout, and validate on borrow.

**Measure what the server saw.** `Max_used_connections` is "the maximum number of connections that have been in use simultaneously since the server started" (with `Max_used_connections_time`), `Connection_errors_max_connections` counts "connections refused because the server max_connections limit was reached", and `Aborted_connects` counts "failed attempts to connect to the MySQL server" ([status variables](https://dev.mysql.com/doc/refman/8.4/en/server-status-variables.html)). If `Max_used_connections` is near the budget, the formula is wrong or a pool leaks.

**RDS Proxy multiplexes only unpinned sessions.** AWS recommends it when applications "frequently open and close connections, or keep a large number of long-lived connections open" ([RDS quotas](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html#RDS_Limits.MaxConnections)). Its `MaxConnectionsPercent` caps database connections as a percentage of the target's `max_connections` ([proxy connections](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-connections.html)). For MySQL it pins on `LOCK TABLE(S)` and `FLUSH TABLES WITH READ LOCK`, `GET_LOCK`, setting a user or system variable (with exceptions), temporary tables, prepared statements (SQL text or binary protocol), sometimes `ROW_COUNT`/`FOUND_ROWS`, executable comments (`/*! ... */`), and any statement over 16 KB ([RDS Proxy pinning](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-pinning.html)). It tracks, without pinning, `USE`, `autocommit`, `sql_mode`, `time_zone`, the character set and collation variables, `wait_timeout`, `interactive_timeout`, `net_write_timeout`, and session-scope `transaction_isolation`/`transaction_read_only` (next-transaction scope pins). AWS also states "RDS Proxy does not pin connections when you use SET LOCAL"; note that in MySQL `SET LOCAL` sets the session value, the same as `SET SESSION` ([SET syntax](https://dev.mysql.com/doc/refman/8.4/en/set-variable.html)), so test your driver's statements against the `DatabaseConnectionsCurrentlySessionPinned` metric rather than relying on the keyword. Identical setup `SET`s belong in the proxy's initialization query. The proxy also caps client connection life at 24 hours, so keep pool max lifetime below that too.

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
SELECT @@GLOBAL.max_connections AS max_connections,
1 AS admin_extra_slot,
10 AS admin_and_monitoring;

SELECT SUM((replicas + surge) * processes * pool_max) AS peak_connections
FROM fleet;

CREATE USER 'orders_app'@'%' IDENTIFIED BY 'orders-app-pw'
WITH MAX_USER_CONNECTIONS 24;

COALESCE(NULLIF(max_user_connections, 0),
NULLIF(@@GLOBAL.max_user_connections, 0)) AS effective_limit
```

The test computes the budget from `@@GLOBAL.max_connections` and reads `Max_used_connections`, `Threads_connected`, `Aborted_connects` and `Connection_errors_max_connections` from `performance_schema.global_status`. It sizes a fleet with the deploy surge included (33 connections), asserts it fits and that every pool lifetime is below `wait_timeout`. It creates two accounts `WITH MAX_USER_CONNECTIONS`, asserts the effective limits from `mysql.user` add up to no more than the budget, that `orders_app` is capped at its fleet peak of 24, and that neither account holds `CONNECTION_ADMIN` or `SUPER`. Last, it counts connections per account in `performance_schema.accounts` and `performance_schema.threads`. It runs on MySQL 8.4 and 9.7.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: the estimate multiplies replicas by pool and forgets the worker
-- processes: 12 * 4 = 48 looks like it fits a 60-connection server.
CALL assert_true((SELECT replicas * pool_max FROM fleet) = 48,
'the naive estimate says 48');

-- MISTAKE: the application account has no MAX_USER_CONNECTIONS (0, the
-- default) and the global max_user_connections is 0 too, so the account is
-- unlimited: one leaking pool can take every slot and starve the others.
CREATE USER 'reports_app'@'%' IDENTIFIED BY 'reports-app-pw';
```

The assertions describe the bad outcome: the real fleet needs 96 connections at steady state against a 60-connection db.t3.micro and 120 mid-deploy, the pool never retires connections while `wait_timeout` closes them after 28800 s, `reports_app` has no limit at either level, and a `CONNECTION_ADMIN` grant lets it take the administrators' extra slot. If the arithmetic or a default ever changes, the example fails.

## Checklist

When reviewing pool settings, deploy manifests, account DDL or database settings under this skill, confirm:

- [ ] The budget uses `@@GLOBAL.max_connections` from the real server, minus an admin/monitoring/migration reserve, and does not count the extra `CONNECTION_ADMIN` slot.
- [ ] The fleet peak multiplies replicas (at autoscaler max, plus deploy surge) × processes per replica × pool max, for every service, worker, cron and migration job.
- [ ] The fleet peak fits the budget; if it does not, the fix is RDS Proxy or fewer, larger pools, not a higher `max_connections`.
- [ ] Every application account is created or altered `WITH MAX_USER_CONNECTIONS` > 0, and the limits add up to no more than the budget.
- [ ] No application account has `CONNECTION_ADMIN` or `SUPER`.
- [ ] Pool max lifetime is below `wait_timeout` (and below 24 hours behind RDS Proxy), and the pool validates connections on borrow.
- [ ] `Max_used_connections` and `Connection_errors_max_connections` are monitored, and connections per account in `performance_schema.accounts` match the formula.
- [ ] Behind RDS Proxy, setup `SET`s live in the initialization query, code avoids prepared statements, temporary tables, `LOCK TABLES` and `GET_LOCK` on the request path, and `DatabaseConnectionsCurrentlySessionPinned` is monitored.

## When not to apply

- A single service with a handful of connections far below the budget: compute the budget once, set `MAX_USER_CONNECTIONS`, and skip the proxy; it adds a hop and a failure point for nothing.
- Code that needs session state (prepared statements, `GET_LOCK`, temporary tables): give it a direct connection or its own small pool, sized in the budget, and keep RDS Proxy for the request path.
- Many accounts with the same shape: set the global `max_user_connections` as a default cap, and use per-account `MAX_USER_CONNECTIONS` only where an account needs a different share.
- Aurora readers and RDS read replicas: each instance has its own `max_connections`; compute a separate budget per instance for the services that read from it.
- Event scheduler jobs: their sessions run as the `event_scheduler` user, not as the event's `DEFINER`, so the definer's `MAX_USER_CONNECTIONS` does not bound them; keep events few and short instead.
