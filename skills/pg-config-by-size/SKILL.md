---
name: pg-config-by-size
description: Use when setting PostgreSQL memory settings, writing a postgresql.conf or RDS parameter group, picking an instance size, or a sort or hash spills to disk. Key rules: shared_buffers about 25% of RAM; work_mem multiplies by connections x sort/hash nodes, so raise it for one query with SET LOCAL inside its transaction, never globally; effective_cache_size is only a planner hint; on RDS change the parameter group and use only AWS-documented formulas.
metadata:
  verified: 2026-10-18
---

# Size PostgreSQL settings from the instance and the workload

## The decision

Which server settings to derive from the instance (RAM, storage) and the workload (connections, query shape), and which to leave at their defaults. It comes up when you provision an instance, change instance class, or chase a slow report. Getting it wrong costs in two directions: settings that are too small push sorts and hashes to temporary files and make the planner avoid good index plans; settings that are too big, multiplied by every connection, overcommit memory until the OOM killer ends a backend and PostgreSQL restarts every session. On RDS a `shared_buffers` or `max_connections` value that is too high stops the instance from starting at all.

## The rule

1. Set `shared_buffers` to about 25% of RAM on a dedicated server with 1GB or more, and rarely above 40%.
2. Set `effective_cache_size` to the memory you expect to cache data (shared_buffers plus the OS page cache), knowing it is only a planner hint and allocates nothing.
3. Keep the global `work_mem` small and size it as `max_connections × sort/hash nodes per query × work_mem × hash_mem_multiplier`, which must fit in the RAM left after `shared_buffers`.
4. Raise `work_mem` for the one query that needs it with `SET LOCAL` inside its transaction (or per role), never globally to fix one report.
5. Raise `maintenance_work_mem` for index builds and vacuum, remembering that autovacuum can allocate it once per `autovacuum_max_workers`.
6. Change `random_page_cost` only with evidence from `EXPLAIN` on your own workload, never from a number copied out of a tuning guide.
7. Keep the PG 18 async I/O defaults (`io_method = worker`, `effective_io_concurrency = 16`) unless a measurement says otherwise (PG 18+).
8. On RDS and Aurora, change settings in a custom parameter group (not `postgresql.conf`), use only AWS-documented formulas, and expect some community settings not to exist on Aurora.

## Why

**1. shared_buffers at 25%, rarely above 40%.** The official guidance: "If you have a dedicated database server with 1GB or more of RAM, a reasonable starting value for shared_buffers is 25% of the memory in your system", and "because PostgreSQL also relies on the operating system cache, it is unlikely that an allocation of more than 40% of RAM to shared_buffers will work better than a smaller amount." The compiled-in default is typically 128MB, which is far below 25% of any production instance. It is a `postmaster` setting: it needs a restart, and on RDS it is a static parameter that needs a reboot. Source: [Resource Consumption (PG 18)](https://www.postgresql.org/docs/18/runtime-config-resource.html#GUC-SHARED-BUFFERS).

**2. effective_cache_size is a hint.** It "has no effect on the size of shared memory allocated by PostgreSQL, nor does it reserve kernel disk cache; it is used only for estimation purposes." A higher value makes index scans more likely, a lower one sequential scans. The default is 4GB, so on a large instance the planner underestimates the cache; on a small one it overestimates it. The good example asserts its `pg_settings.context` is `user`: you can change it per session with no memory cost. Source: [Query Planning (PG 18)](https://www.postgresql.org/docs/18/runtime-config-query.html#GUC-EFFECTIVE-CACHE-SIZE).

**3. work_mem multiplies.** `work_mem` (default 4MB) is "the base maximum amount of memory to be used by a query operation (such as a sort or hash table) before writing to temporary disk files". A complex query "might perform several sort and hash operations at the same time", "several running sessions could be doing such operations concurrently", so "the total memory used could be many times the value of work_mem". Hash operations get `work_mem × hash_mem_multiplier`, and the multiplier defaults to 2.0. Sorts serve `ORDER BY`, `DISTINCT` and merge joins; hash tables serve hash joins, hash aggregation, memoize and hashed `IN` subqueries. Source: [Resource Consumption (PG 18)](https://www.postgresql.org/docs/18/runtime-config-resource.html#GUC-WORK-MEM). The bad example does the multiplication: 100 connections × 2 nodes × 256MB is 50GB of possible work memory, on top of `shared_buffers`, against a 16GB instance. `max_connections` is the other factor of this product; keep it low and put a pooler in front, as `pg-connections` covers.

**4. SET LOCAL scopes the raise.** `SET LOCAL` lasts until the end of the current transaction ([SET](https://www.postgresql.org/docs/18/sql-set.html)). The good example sorts 300,000 rows: at 4MB the sort spills to disk (`Sort Space Type: Disk`, external merge), and under `SET LOCAL work_mem = '128MB'` the same sort runs in memory (`Memory`, quicksort). After `COMMIT` the session is back at the global value, so no other query inherits the 128MB. `ALTER ROLE reporting SET work_mem = ...` is the same idea for a role that only runs reports.

**5. maintenance_work_mem.** It defaults to 64MB and governs `VACUUM`, `CREATE INDEX` and `ALTER TABLE ADD FOREIGN KEY`; "larger settings might improve performance for vacuuming and for restoring database dumps." Because "when autovacuum runs, up to autovacuum_max_workers times this memory may be allocated", count it in the budget, or cap autovacuum separately with `autovacuum_work_mem` (-1 means it falls back to `maintenance_work_mem`). On PG 15 and 16, VACUUM uses at most 1GB of it for dead tuple identifiers ([PG 15 docs](https://www.postgresql.org/docs/15/runtime-config-resource.html#GUC-MAINTENANCE-WORK-MEM)); PG 17 removed that cap ([PG 17 release notes](https://www.postgresql.org/docs/17/release-17.html)). For a one-off index build, raise it with `SET` in the session that runs `CREATE INDEX`. Source: [Resource Consumption (PG 18)](https://www.postgresql.org/docs/18/runtime-config-resource.html#GUC-MAINTENANCE-WORK-MEM).

**6. random_page_cost needs evidence.** The default is 4.0 (`seq_page_cost` is 1.0). The docs explain the default assumes most random reads hit cache, and that "if your data is likely to be completely in cache, such as when the database is smaller than the total server memory, or network latency is high, decreasing random_page_cost might be appropriate", while setting it below `seq_page_cost` "is not physically sensible". The docs give no SSD value. Lower it only after `EXPLAIN (ANALYZE, BUFFERS)` shows the planner choosing a sequential scan that is slower than the index plan, and test the new value per session first. Source: [Query Planning (PG 18)](https://www.postgresql.org/docs/18/runtime-config-query.html#GUC-RANDOM-PAGE-COST). On RDS, the parameter list notes `random_page_cost` "has no value unless query plan management (QPM) is turned on" ([RDS parameters](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Parameters.html)).

**7. PG 18 async I/O.** `io_method` is `worker` (the default), `io_uring` (only in builds with liburing) or `sync`, and "can only be set at server start". `io_workers` defaults to 3. `effective_io_concurrency` and `maintenance_io_concurrency` default to 16 in PG 18; on PG 15 `effective_io_concurrency` defaults to 1. The good example asserts these defaults on PG 18 and that `io_method` does not exist on PG 15. Sources: [Resource Consumption (PG 18)](https://www.postgresql.org/docs/18/runtime-config-resource.html#GUC-IO-METHOD), [PG 15](https://www.postgresql.org/docs/15/runtime-config-resource.html#GUC-EFFECTIVE-IO-CONCURRENCY).

**8. RDS and Aurora.** You cannot change values in the default parameter groups; create a custom DB parameter group, change it, and attach it. Static parameters (`shared_buffers`, `max_connections`, `autovacuum_max_workers`) need a reboot; dynamic ones (`work_mem`, `maintenance_work_mem`, `effective_cache_size`) do not, and `SET`/`ALTER ROLE`/`ALTER DATABASE` still work. Values too high for the instance make it fail to start with "could not map anonymous shared memory" ([RDS parameters](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Parameters.html)). Formulas use `DBInstanceClassMemory`, which is the instance memory minus what the OS and RDS reserve, in bytes ([Specifying DB parameters](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ParamValuesRef.html)). The documented PostgreSQL default for `max_connections` is `LEAST({DBInstanceClassMemory/9531392}, 5000)` ([RDS quotas](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html#RDS_Limits.MaxConnections)). Read the other defaults from your parameter group or `pg_settings` instead of copying formulas from blog posts. On Aurora PostgreSQL, "io_method, io_workers and io_max_concurrency are community AIO GUCs and are not available in Aurora PostgreSQL. Aurora PostgreSQL uses its own async I/O implementation" ([Aurora PostgreSQL 18.3 release notes](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraPostgreSQLReleaseNotes/AuroraPostgreSQL.Updates.html)).

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
BEGIN;
SET LOCAL work_mem = '128MB';
SELECT assert_true(
  sort_space_type('SELECT id, payload FROM events ORDER BY payload') = 'Memory',
  'with SET LOCAL work_mem = 128MB the sort runs in memory (quicksort)');
COMMIT;
```

The budget is computed from the live settings, never from guesses:

```sql
SELECT pg_size_bytes(current_setting('shared_buffers')) AS shared_buffers,
current_setting('max_connections')::bigint AS max_connections,
pg_size_bytes(current_setting('work_mem')) AS work_mem,
current_setting('hash_mem_multiplier')::numeric AS hash_mem_multiplier,
2 AS nodes_per_query,
pg_size_bytes(current_setting('maintenance_work_mem')) AS maintenance_work_mem,
current_setting('autovacuum_max_workers')::bigint AS autovacuum_workers;
```

The test asserts that the sort runs in memory under `SET LOCAL`, that `work_mem` is back to its global value after `COMMIT`, and that `shared_buffers + max_connections × 2 × work_mem × hash_mem_multiplier + autovacuum_max_workers × maintenance_work_mem` fits in 75% of a 16GB instance. It also asserts that `effective_cache_size` is a per-session setting while `shared_buffers` needs a restart, and, on PG 18 only, that `io_method` is `worker` and `effective_io_concurrency` is 16.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: work_mem raised globally (here for the session; in production
-- in postgresql.conf or the parameter group) to fix one slow report.
SET work_mem = '256MB';
-- MISTAKE: 100 connections x 2 nodes x 256MB = 50GB of possible work
-- memory on a 16GB instance. Under load the kernel OOM killer ends a
SELECT assert_true(
shared_buffers + max_connections * nodes_per_query * work_mem
> pg_size_bytes('16GB'),
'global work_mem x max_connections x nodes exceeds a 16GB instance')
FROM budget;
```

```sql
RESET work_mem;
-- MISTAKE: the report runs at the default work_mem (4MB), so its sort
-- spills to temporary files (external merge) instead of sorting in memory.
SELECT assert_true(
sort_space_type('SELECT id, payload FROM events ORDER BY payload') = 'Disk',
'at the default work_mem the sort spills to disk (external merge)');
```

The assertions describe the bad outcome: the worst-case work memory exceeds the instance, and the same sort as the good example runs on disk. If the sort ever stops spilling at 4MB, the example fails and has to be rebuilt with more rows.

## Checklist

When reviewing a postgresql.conf, a parameter group or a `SET` in application code, confirm:

- [ ] Is `shared_buffers` near 25% of the instance memory and not above 40%?
- [ ] Is `effective_cache_size` set from the memory that actually caches data, not left at 4GB on a much larger or smaller instance?
- [ ] Does `shared_buffers + max_connections × nodes × work_mem × hash_mem_multiplier + autovacuum_max_workers × maintenance_work_mem` fit in RAM with room for the OS?
- [ ] Is every `work_mem` raise for one query a `SET LOCAL` inside a transaction (or a role setting), not a global change?
- [ ] Do the reported sorts or hashes that spill (`Sort Space Type: Disk`, `log_temp_files`) have a scoped raise instead of a higher global `work_mem`?
- [ ] Does every change to `random_page_cost` come with an `EXPLAIN (ANALYZE, BUFFERS)` comparison from this workload?
- [ ] On PG 18 self-managed, are `io_method` and `effective_io_concurrency` at their defaults or backed by a measurement?
- [ ] On RDS/Aurora, are changes in a custom parameter group, with static parameters scheduled for a reboot and no settings Aurora does not expose?
- [ ] Is every formula or number traceable to postgresql.org or docs.aws.amazon.com?

## When not to apply

- **Shared or non-dedicated hosts** (a laptop, a container next to the application): the 25% guidance is for a dedicated server. Size `shared_buffers` from the memory the container is allowed, not the host's RAM.
- **Batch or analytics instances with few connections**: with 5 connections, a large global `work_mem` can fit the budget. Do the same multiplication; if it fits, a global raise is fine.
- **Managed defaults you have not measured against**: on RDS the default parameter group already sets values per instance class (`max_connections` scales with `DBInstanceClassMemory`). Read them with `pg_settings` and keep them until `pg_stat_statements`, temp-file logs or plans show a problem, then change one setting at a time.
- **Aurora**: storage and async I/O are Aurora's own; skip the `io_method` and `io_workers` advice, and check which parameters the cluster parameter group exposes before planning a change.
