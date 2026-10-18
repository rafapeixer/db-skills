# Throughput per connection

The same four API requests written two ways, measured with `pgbench` (the official PostgreSQL benchmark tool) so the result does not depend on an application language.

```bash
bash benchmarks/throughput/run.sh 0.5ms 20   # network RTT, seconds per point
```

- **Database:** PostgreSQL 17 in Docker, limited to 2 vCPU and 1 GiB like an RDS db.t4g.micro, `max_connections=100`, `shared_buffers=256MB`. Schema and data: [`setup.sql`](setup.sql) (20,000 customers, 300,000 orders, 900,000 items, 2 million queued jobs).
- **Client:** `pgbench -M prepared` in a separate container with **0.5 ms of network latency** added with `netem`, about what an application sees to a database in the same availability zone. Without it, Docker's near-zero latency would hide the cost of round trips.
- **Lock waits:** sessions in `pg_stat_activity` with `wait_event_type = 'Lock'`, sampled every 0.5 s during each run.
- **Scripts:** [`scripts/`](scripts/), one file per request and variant.

## Results (October 2026, 20 s per point)

| Request | Variant | 4 connections | 16 connections | 64 connections | Latency at 4 | Sessions waiting on locks at 64 |
|---|---|---|---|---|---|---|
| Page of 10 orders with items | N+1, 11 round trips | 582 tps | 2,179 | 1,840 | 6.87 ms | 0 |
| | one LATERAL statement | **5,893** | **15,047** | 10,665 | **0.68 ms** | 0 |
| Create order with 3 items | BEGIN + 4 statements + COMMIT | 924 | 3,279 | 3,131 | 4.33 ms | 0 |
| | one CTE statement | **2,405** | **8,464** | 7,600 | **1.66 ms** | 0 |
| Claim a job | FOR UPDATE, work inside the transaction | 339 | 337 | 333 | 11.8 ms | **40** |
| | FOR UPDATE SKIP LOCKED, work after commit | **1,656** | **4,994** | 1,095 | **2.42 ms** | 0.3 |
| Decrement a hot counter | one row | 1,671 | 1,463 | 1,348 | 2.39 ms | 12.7 |
| | 16 shards | **2,372** | **6,681** | 6,017 | **1.69 ms** | 22.2 |

Raw numbers: [`results.csv`](results.csv).

## What it shows

- **More volume with fewer connections.** The one-statement page with 4 connections serves 3.2 times what the N+1 page serves with 64.
- **Faster requests.** Removing round trips cut page latency from 6.87 ms to 0.68 ms.
- **No lock queue.** Plain `FOR UPDATE` caps the queue at about 335 claims per second no matter how many connections you add, with 40 of 64 sessions waiting; `SKIP LOCKED` removes the wait and serves 15 times more.
- **More connections can mean less throughput.** On this 2-vCPU database every optimized variant did better with 16 connections than with 64.

## Limits

- One host runs the client and the database; the database container is CPU-limited, the client is not.
- `netem` adds latency on the client's egress only, which approximates a round trip.
- Each point ran once for 20 seconds; expect a few percent of variation between runs.
