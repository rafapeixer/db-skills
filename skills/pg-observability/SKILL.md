---
name: pg-observability
description: Use when setting up or reading PostgreSQL query monitoring, finding which queries cost the most, or about to run EXPLAIN ANALYZE against a real database. Covers pg_stat_statements ranked by total_exec_time and its normalization limits, track_io_timing, log_min_duration_statement and sampled auto_explain, safe EXPLAIN (ANALYZE, BUFFERS), wait events in pg_stat_activity, pg_stat_io (PG 16+, changed in 18), and RDS Database Insights.
metadata:
  verified: 2026-10-18
---

# Finding the queries that cost the most

## The decision

Before you tune anything, decide what you turn on and what you read to learn where the server's time goes. Without it you tune the query someone complained about, not the one that eats the CPU: a 2 ms lookup called millions of times costs more than a 30 s report run once a day, and only a cumulative, normalized view of every statement shows that. The wrong instrument costs you in three ways: you optimize the wrong query, you leave heavy overhead switched on (per-node timing on every statement), or you "just look at the plan" of an `UPDATE` with `EXPLAIN ANALYZE` and change production data.

## The rule

1. Preload `pg_stat_statements` on every server, run `CREATE EXTENSION pg_stat_statements` in every database you will read it from, and rank by `total_exec_time`, not `mean_exec_time`.
2. Read the stored text as a normalized template (`$1`, `$2`), and check `pg_stat_statements_info.dealloc` before trusting it: when entries are evicted, literals can show up in the text and history is lost.
3. Turn on `track_io_timing` after measuring its cost with `pg_test_timing`, so the I/O time columns in `pg_stat_statements`, `pg_stat_io` and `EXPLAIN (BUFFERS)` stop reading zero.
4. Set `log_min_duration_statement` at your latency objective as a backstop that records the literal slow statement, and never at `0` on a busy server.
5. Preload `auto_explain` with `log_min_duration` above the objective, `log_analyze = on`, `log_timing = off` and `sample_rate` below 1, so slow plans reach the log without timing every node of every statement.
6. Run `EXPLAIN (ANALYZE, BUFFERS)` only on reads, or on writes inside `BEGIN; ... ROLLBACK;` in a sandbox, never on a production write: ANALYZE executes the statement, and `ROLLBACK` does not undo sequences.
7. For "what is slow right now", group active sessions in `pg_stat_activity` by `wait_event_type` and `wait_event`; for cluster I/O by backend and context, read `pg_stat_io` (PG 16+, `op_bytes` replaced by `read_bytes`/`write_bytes`/`extend_bytes` in PG 18).
8. On RDS, use Database Insights (built on Performance Insights) for DB load by wait and top SQL, and take its behavior and settings only from the AWS documentation.

## Why

**Preload, then create the extension per database.** The module "must be loaded by adding `pg_stat_statements` to shared_preload_libraries ... a server restart is needed to add or remove the module". It "tracks statistics across all databases of the server", but the views and functions "are not available globally but can be enabled for a specific database with `CREATE EXTENSION pg_stat_statements`". It also needs query IDs, which `compute_query_id = auto` (the default) turns on automatically. `pg_stat_statements.track` defaults to `top`: statements inside functions are not tracked unless you set it to `all`. Source: [pg_stat_statements](https://www.postgresql.org/docs/18/pgstatstatements.html), [compute_query_id](https://www.postgresql.org/docs/18/runtime-config-statistics.html). On RDS, `shared_preload_libraries` is a static parameter (reboot) that accepts `pg_stat_statements` and `auto_explain` ([RDS parameters](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Parameters.html)).

**Total, not mean.** `total_exec_time` is the server time a query consumed; `mean_exec_time` is cost per call and ignores frequency. In the example, a lookup called 500 times took 1042.6 ms in total at 2.09 ms per call, and a report called 3 times took 82.6 ms in total at 27.55 ms per call (one run on PG 18 in Docker). Mean puts the report first; total shows the lookup costs about 12 times more. Use mean and `stddev_exec_time` second, to decide how to fix the query you already picked.

**Normalization and its leak.** "When a constant's value has been ignored for purposes of matching the query to other queries, the constant is replaced by a parameter symbol, such as `$1`". The example sends 500 statements with 500 different ids and finds one entry with 500 calls. But "queries on which normalization can be applied may be observed with constant values in `pg_stat_statements`, especially when there is a high rate of entry deallocations". `pg_stat_statements.max` defaults to 5000; `pg_stat_statements_info.dealloc` counts how many times the least-executed entries were thrown out to make room. A growing `dealloc` means raise `max` (restart) and treat stored text as possibly containing literal values, including personal data. PG 18 also squashes `IN` lists that differ only in length into one entry, so `IN ($1 /*, ... */)` is one query. `track_planning` defaults to `off` because it "may incur a noticeable performance penalty". Source: [pg_stat_statements](https://www.postgresql.org/docs/18/pgstatstatements.html).

**Do not reset to get a window.** `pg_stat_statements_reset()` erases everyone's history. Take two snapshots and diff them, or read `stats_since` (PG 17+) per entry. The example resets one test database only because it is a sandbox.

**`track_io_timing`.** It is off by default "as it will repeatedly query the operating system for the current time, which may cause significant overhead on some platforms. You can use the pg_test_timing tool to measure the overhead". When off, `shared_blk_read_time` reads zero, and so do the time columns of `pg_stat_io` and the I/O timings in `EXPLAIN (BUFFERS)`. Source: [track_io_timing](https://www.postgresql.org/docs/18/runtime-config-statistics.html). It is a dynamic parameter on RDS (no reboot).

**`log_min_duration_statement` is the backstop.** It logs each completed statement that ran at least the given time; `-1` (the default) disables it, and `0` logs every statement. It catches what `pg_stat_statements` cannot: the literal text and timestamp of one slow call. When the volume is too high, `log_min_duration_sample` with `log_statement_sample_rate` logs a fraction. Logged statements "might reveal sensitive data". Source: [logging](https://www.postgresql.org/docs/18/runtime-config-logging.html). Database Insights' slow SQL view on RDS for PostgreSQL reads these logs from CloudWatch Logs, with `log_min_duration_statement = 1000` as AWS's example value ([Slow SQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DatabaseInsights.SlowSQL.html)).

**`auto_explain` with sampling.** The default "is to do nothing": `auto_explain.log_min_duration` is `-1`. With `log_analyze` on, "per-plan-node timing occurs for all statements executed, whether or not they run long enough to actually get logged. This can have an extremely negative impact on performance. Turning off `auto_explain.log_timing` ameliorates the performance cost". `sample_rate` (default 1) explains only a fraction of statements. `log_buffers` adds buffer counts. All of these are superuser settings. Source: [auto_explain](https://www.postgresql.org/docs/18/auto-explain.html).

**EXPLAIN ANALYZE executes.** "The statement is actually executed when the `ANALYZE` option is used ... other side effects of the statement will happen as usual." For `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `CREATE TABLE AS` or `EXECUTE`, the docs give `BEGIN; EXPLAIN ANALYZE ...; ROLLBACK;` ([EXPLAIN](https://www.postgresql.org/docs/18/sql-explain.html)). Even then, "the value obtained by `nextval` is not reclaimed for re-use if the calling transaction later aborts" ([sequence functions](https://www.postgresql.org/docs/18/functions-sequence.html)): the example's rolled-back `INSERT` leaves the identity sequence one higher. Row locks are held until the `ROLLBACK`, triggers fire and WAL is written, which is why this belongs in a sandbox, not on production. PG 18 adds BUFFERS to `EXPLAIN ANALYZE` automatically; on 15 to 17 you ask for it. `TIMING OFF` cuts clock overhead and keeps row counts.

**Wait events show the present.** `wait_event_type` and `wait_event` are NULL when the backend is not waiting; an `active` session with a wait event "is being executed, but is being blocked somewhere in the system". Join `pg_wait_events` (PG 17+) for descriptions. Source: [monitoring stats](https://www.postgresql.org/docs/18/monitoring-stats.html).

**`pg_stat_io` is version-specific.** It shows "cluster-wide I/O statistics", one row per backend type, object and context. PG 18 added `read_bytes`, `write_bytes` and `extend_bytes`, removed `op_bytes` ("which always equaled BLCKSZ"), and added WAL rows ([PG 18 release notes](https://www.postgresql.org/docs/18/release-18.html), [PG 16 pg_stat_io](https://www.postgresql.org/docs/16/monitoring-stats.html)). Monitoring SQL that selects `op_bytes` fails on 18; check `server_version_num` first.

**RDS Database Insights.** DB load is measured in average active sessions (AAS), sampled every second and sliced by wait events, top SQL, hosts and users. Advanced mode needs Performance Insights on with a retention of at least 465 days ([Database Insights](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DatabaseInsights.html), [DB load](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.Overview.ActiveSessions.html), [Advanced mode](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DatabaseInsights.TurningOnAdvanced.html)). It complements `pg_stat_statements`; it does not replace it.

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
SELECT format('SELECT status, pg_sleep(0.002) FROM obs_orders WHERE id = %s', g) FROM generate_series(1, 500) AS g \gexec
SELECT customer_id, sum(amount) FROM obs_orders GROUP BY customer_id ORDER BY 2 DESC LIMIT 10;

-- Rank by total_exec_time: the share of server time each query takes.
SELECT queryid, calls, round(total_exec_time::numeric, 1) AS total_ms,
round(mean_exec_time::numeric, 2) AS mean_ms, left(query, 70) AS query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC
LIMIT 10;

-- Literals leak back when entries are evicted: watch dealloc.
SELECT dealloc, stats_reset FROM pg_stat_statements_info;
```

```sql
SET auto_explain.log_min_duration = '500ms';
SET auto_explain.log_analyze = on;
SET auto_explain.log_timing = off;
SET auto_explain.sample_rate = 0.1;
```

```sql
-- EXPLAIN ANALYZE on a write: only inside BEGIN/ROLLBACK, in a sandbox.
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
INSERT INTO obs_orders (customer_id, amount, status) VALUES (1, 9.99, 'paid');
ROLLBACK;
-- The sequence is not rolled back: nextval is never reclaimed.
SELECT assert_true(last_value = :seq_before + 1, 'ROLLBACK did not undo nextval') FROM obs_orders_id_seq;
```

The test runs 500 cheap lookups with 500 different literals and 3 runs of an expensive report, then asserts that the lookup tops the `total_exec_time` ranking, that the 500 calls share one entry, and that no literal survives in its text. It checks the defaults (`track_io_timing` off, `log_min_duration_statement` `-1`, `pg_stat_statements.max` 5000), sets sampled `auto_explain`, runs `EXPLAIN (ANALYZE, BUFFERS)` on a `SELECT` and reads shared hits and actual rows, then explains an `INSERT` inside `BEGIN/ROLLBACK` and asserts the row count did not change while the sequence moved by one. It reads wait events from `pg_stat_activity` and checks `pg_stat_io`: absent on 15, with `op_bytes` on 16 and 17, with `read_bytes` and without `op_bytes` on 18.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: ranking by mean_exec_time puts the 3-call report first and
-- hides the lookup that spends more server time in total; you tune the
-- wrong query.
SELECT calls, round(mean_exec_time::numeric, 2) AS mean_ms, left(query, 70) AS query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY mean_exec_time DESC
LIMIT 10;
```

```sql
-- MISTAKE: EXPLAIN ANALYZE executes the statement. Without BEGIN/ROLLBACK
-- this "just a plan" check inserts a real row (and fires triggers, takes
-- locks and writes WAL), which on production is a data change.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
INSERT INTO obs_orders (customer_id, amount, status) VALUES (1, 9.99, 'paid');
```

The assertions describe the bad outcome: the mean ranking puts the report first while its `total_exec_time` is lower than the lookup's, and after the explained `INSERT` the table has 200001 rows instead of 200000.

## Checklist

When reviewing monitoring setup or a performance investigation under this skill, confirm:

- [ ] Is `pg_stat_statements` in `shared_preload_libraries`, and does the extension exist in each database you read it from?
- [ ] Is the top-queries list ordered by `total_exec_time` (mean and stddev used only after picking the query)?
- [ ] Was `pg_stat_statements_info.dealloc` checked, and is `pg_stat_statements.max` raised if it grows?
- [ ] Are time windows taken from snapshots or `stats_since`, not from `pg_stat_statements_reset()` on a shared server?
- [ ] Is `track_io_timing` on (after `pg_test_timing`), so I/O time columns are not silently zero?
- [ ] Is `log_min_duration_statement` set at the latency objective, not `-1` and not `0` on a busy server?
- [ ] Does `auto_explain` with `log_analyze` also have `log_timing = off` or `sample_rate` below 1?
- [ ] Is every `EXPLAIN ANALYZE` of a write inside `BEGIN ... ROLLBACK` on a sandbox, never on production?
- [ ] Does monitoring SQL gate `pg_stat_io` on `server_version_num` (absent before 16, `op_bytes` gone in 18)?

## When not to apply

- Throwaway local or CI databases: you can reset `pg_stat_statements` freely and run `EXPLAIN ANALYZE` on writes without a transaction, because no one else's data or history is at stake.
- Diagnosing a single slow request you already identified: go straight to `EXPLAIN (ANALYZE, BUFFERS)` on the read (or plain `EXPLAIN`, or `EXPLAIN (GENERIC_PLAN)` on PG 16+ for a `$1` text) instead of building a ranking.
- Managed services where you cannot set `shared_preload_libraries` or superuser-only parameters: use the provider's tools (on RDS, Database Insights and the parameter group) and read their documentation for what they capture.
- Workloads where most time is spent inside functions: set `pg_stat_statements.track = all`, or the ranking only shows the outer `SELECT my_function()` call.
