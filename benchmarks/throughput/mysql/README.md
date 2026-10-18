# Throughput per connection (MySQL)

The same four API requests as the [PostgreSQL benchmark](../README.md), written two ways, measured with [sysbench](https://github.com/akopytov/sysbench) 1.0.20 so the result does not depend on an application language.

```bash
bash benchmarks/throughput/mysql/run.sh 0.5ms 20   # network RTT, seconds per point
```

- **Database:** MySQL 8.4 in Docker, limited to 2 vCPU and 1 GiB like an RDS db.t4g.micro, `max_connections=100`, `innodb_buffer_pool_size=512M`. RDS defaults the buffer pool to 75% of memory (`{DBInstanceClassMemory*3/4}`, where `DBInstanceClassMemory` is already less than the class's memory) and may lower it on micro classes ([RDS parameter formulas](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ParamValuesRef.html), [RDS troubleshooting](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Troubleshooting.html#Troubleshooting.FreeableMemory), [buffer pool override](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.KnownIssuesAndLimitations.html#MySQL.Concepts.KnownIssuesAndLimitations.innodb-bp-size)); 512 MB holds the whole data set and leaves the container room for connections. Everything else is the 8.4 default: REPEATABLE READ, binary log on, `sync_binlog=1`, `innodb_flush_log_at_trx_commit=1`. TLS is off, as in the PostgreSQL run. Schema and data: [`setup.sql`](setup.sql) (20,000 customers, 300,000 orders, 900,000 items, 2 million queued jobs, InnoDB, `BIGINT AUTO_INCREMENT` keys).
- **Client:** sysbench in a separate Ubuntu 24.04 container with **0.5 ms of network latency** added with `netem`. Statements go through server-side prepared statements (`--db-ps-mode=auto`), except `BEGIN`/`COMMIT` and the first query of the N+1 page (see below).
- **Lock waits:** transactions waiting on a row lock, `COUNT(DISTINCT REQUESTING_ENGINE_TRANSACTION_ID)` from `performance_schema.data_lock_waits`, sampled every 0.5 s during each run.
- **Scripts:** [`scripts/`](scripts/), one Lua file per request and variant.

## Results (October 2026, 20 s per point)

| Request | Variant | 4 connections | 16 connections | 64 connections | Latency at 4 | Transactions waiting on locks at 64 |
|---|---|---|---|---|---|---|
| Page of 10 orders with items | N+1, 11 round trips | 551 tps | 1,743 | 1,426 | 7.26 ms | 0 |
| | one LATERAL statement with `JSON_ARRAYAGG` | **5,108** | **7,477** | **5,741** | **0.78 ms** | 0 |
| Create order with 3 items | BEGIN + 4 INSERTs + COMMIT, 6 round trips | 613 | 1,945 | 2,595 | 6.52 ms | 0 |
| | BEGIN + INSERT + multi-row INSERT + COMMIT, 4 round trips | **665** | **2,330** | **3,256** | **6.01 ms** | 0 |
| Claim a job | FOR UPDATE, work inside the transaction | 218 | 214 | 96 | 18.3 ms | **34.6** |
| | FOR UPDATE SKIP LOCKED, work after commit | **625** | **1,937** | **284** | **6.40 ms** | 0 |
| Decrement a hot counter | one row | 518 | 519 | 513 | 7.72 ms | **40.5** |
| | 16 shards | **919** | **2,197** | **3,113** | **4.35 ms** | 24.7 |

Raw numbers: [`results.csv`](results.csv). No run had deadlocks or lock wait timeouts.

## What it shows

- **More volume with fewer connections.** The one-statement page with 4 connections serves 2.9 times the N+1 page's best (16 connections), and latency drops from 7.26 ms to 0.78 ms.
- **Commits cost more than round trips here.** Cutting the order from 6 to 4 round trips gains 8% at 4 connections and 25% at 64. Each commit waits for the redo log and the binary log to reach disk; on this host one connection doing single-row autocommit `UPDATE`s averaged 2.68 ms, of which 0.5 ms is network. Write throughput still rises at 64 connections because concurrent commits share flushes.
- **No lock queue.** Plain `FOR UPDATE` caps the queue at about 215 claims per second at 4 and 16 connections and falls to 96 at 64, with 35 of 64 transactions waiting; `SKIP LOCKED` has no lock waits and serves 9 times more at 16 connections.
- **Sharding a hot row scales; one row does not.** The single counter row stays at about 515 updates per second from 4 to 64 connections; 16 shards reach 3,113 at 64.
- **More connections can mean less throughput.** The page and the `SKIP LOCKED` queue did better with 16 connections than with 64. The queue fell from 1,937 to 284 claims per second with no lock waits. In a repeat run the database used both vCPUs, the claim `SELECT` averaged 99 ms, and the purge backlog (`trx_rseg_history_len`) was 3,872 against 693 at 16 connections, so claimers likely spend the time stepping over locked and delete-marked index entries.

## Differences from the PostgreSQL scripts

- **Write and claim are not one statement.** MySQL has no `INSERT ... RETURNING`, `UPDATE ... RETURNING` or data-modifying CTE. The order's items use `LAST_INSERT_ID()` on the server (`order_items` has no `AUTO_INCREMENT` column, so the value stays the order's id), and the claim keeps its id in a user variable (`SELECT ... INTO @id`). Both good variants need 4 round trips where PostgreSQL needs 1, which is why the write gain here is small.
- **Both queue variants run under READ COMMITTED**, set per session in the scripts. Under the default REPEATABLE READ, moving a row from `'pending'` to `'done'` in the `(status, id)` index needs an insert-intention lock on a gap that other claimers hold with next-key locks, and workers deadlock. In a separate 20 s run under REPEATABLE READ, the `SKIP LOCKED` variant served 351, 328 and 5 claims per second at 4, 16 and 64 connections with 310 to 1,504 deadlocks per second, and the plain `FOR UPDATE` variant served 212 at 4 connections with 646 deadlocks per second and stalled at 16 (one `UPDATE` ran for about 5 minutes holding over 100,000 row locks). MySQL has no partial indexes, so the claim uses `(status, id)` instead of an index on pending rows only.
- **The N+1 page reads the order ids for real.** sysbench cannot read rows from a server-side prepared statement, so the first query of the N+1 page uses the text protocol and the 10 item queries use the ids it returned; still 11 round trips. The PostgreSQL N+1 script looks each order up again with `OFFSET` inside each item query.

## Limits

- One host runs the client and the database; the database container is CPU-limited, the client is not.
- Commit latency depends on the host's disk: Docker Desktop on Windows here, not EBS. Write-heavy numbers will differ on RDS.
- `netem` adds latency on the client's egress only, which approximates a round trip.
- Each point ran once for 20 seconds; expect a few percent of variation between runs. The REPEATABLE READ figures come from one extra run and are not in `results.csv`.
- The numbers are not comparable with the PostgreSQL table: the durability path (binary log plus redo log), the client tool and the round trips per request differ.
