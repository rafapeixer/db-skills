---
name: pg-throughput-per-connection
description: Use when you need more throughput from PostgreSQL, see too many connections, slow under load or lock waits, or want to scale the database without a bigger instance. Key rule: connections needed = requests/s x time each request holds one, so make each request one statement (LATERAL page, WITH ... INSERT ... RETURNING), commit before non-database work, claim with SKIP LOCKED, shard hot counters, and keep the pool small (16 beat 64 on 2 vCPU).
metadata:
  verified: 2026-10-18
---

# Throughput per connection

## The decision

How many requests per second each PostgreSQL connection can serve. It comes up when a service needs more volume, when the fleet hits `too many clients`, or when latency climbs under load while the database CPU looks fine. Little's law sets the arithmetic: connections busy = requests per second × time each request holds a connection. At 1,000 req/s, a request that holds its connection for 6.9 ms keeps about 7 connections busy; one that holds it for 0.68 ms keeps less than 1. Hold time is rarely the SQL itself. It is network round trips (every statement waits a full round trip for its result) and lock waits (a connection queued behind another transaction's row lock does nothing). This skill cuts both, so the same instance serves more volume with fewer connections. How to shape each query lives in [`pg-query-patterns`](../pg-query-patterns/SKILL.md), lock and timeout rules in [`pg-transactions-and-locking`](../pg-transactions-and-locking/SKILL.md), and the connection budget in [`pg-connections`](../pg-connections/SKILL.md).

## The rule

1. Count the round trips of every request and make it one statement where possible: a page and its children with `LEFT JOIN LATERAL`, a parent and its children with one `WITH ... INSERT ... RETURNING`, never `BEGIN` + N statements + `COMMIT`.
2. Never hold a connection or an open transaction across work that is not database work: claim, commit, release the connection, then do the work.
3. Claim queue work in one statement, `UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED)`, never with plain `FOR UPDATE`.
4. Never have every request update the same row: shard a hot counter into N rows, update one shard picked at random and `SUM` to read, or append to a ledger and aggregate.
5. Keep the pool small and find the knee by measuring: past it, more connections lower throughput, and on a 2 vCPU instance 16 beat 64 in every case measured here.
6. When a request needs several independent statements that cannot be merged, send them in a pipeline (libpq pipeline mode, client PG 14+, or your driver's batch API) instead of waiting for each result.

## Why

The numbers below come from this repository's benchmark, [`benchmarks/throughput/`](../../benchmarks/throughput/): PostgreSQL 17 limited to 2 vCPU and 1 GiB like an RDS db.t4g.micro, `pgbench -M prepared` from a client with 0.5 ms of network round trip added with `netem`, 20 s per point, results in `results.csv`. The schema is indexed the same way for both variants, so the only difference is how the request talks to the database.

| Scenario | Variant | 4 conns | 16 conns | 64 conns | Latency at 4 |
|---|---|---|---|---|---|
| Page with items | N+1, 11 round trips | 582 tps | 2,179 tps | 1,840 tps | 6.9 ms |
| Page with items | one `LATERAL` statement | 5,893 tps | 15,047 tps | 10,665 tps | 0.68 ms |
| Order with 3 items | `BEGIN` + 4 statements + `COMMIT` | 924 tps | 3,279 tps | 3,131 tps | 4.3 ms |
| Order with 3 items | one `WITH` statement | 2,405 tps | 8,464 tps | 7,600 tps | 1.7 ms |
| Queue claim | `FOR UPDATE`, work inside | 339 tps | 337 tps | 333 tps | 11.8 ms |
| Queue claim | `SKIP LOCKED`, work after commit | 1,656 tps | 4,994 tps | 1,095 tps | 2.4 ms |
| Hot counter | one row | 1,671 tps | 1,463 tps | 1,348 tps | 2.4 ms |
| Hot counter | 16 shards | 2,372 tps | 6,681 tps | 6,017 tps | 1.7 ms |

**Rule 1.** Each statement a client sends waits for its result before the next one goes out, so a request costs at least its round trips × RTT, and the connection is held for all of it. The naive page did 146 tps per connection at 4 connections; the `LATERAL` page did 1,473, ten times more. With 4 connections the good page (5,893 tps) beats the naive page with 64 (1,840 tps) by 3.2x: no pool size rescues an N+1. The write is the same story: a single statement already runs in its own transaction, because "if you do not issue a `BEGIN` command, then each individual statement has an implicit `BEGIN` and (if successful) `COMMIT` wrapped around it" ([transactions](https://www.postgresql.org/docs/18/tutorial-transactions.html)). In a `WITH` query, "`RETURNING` data is the only way to communicate changes between different `WITH` sub-statements and the main query" ([data-modifying statements in WITH](https://www.postgresql.org/docs/18/queries-with.html#QUERIES-WITH-MODIFYING)), which is exactly how the order's id reaches its items. The good example counts the application session's statements in `pg_stat_statements`: 1 for the page and 1 for the order, against 11 and 6 in the bad example; a duplicate item makes the whole statement fail and leaves no order behind. In the benchmark the one-statement write had 2.6 times the throughput at 4 connections (2,405 against 924 tps).

**Rule 2.** Between round trips of an open transaction the connection is `idle in transaction`: it does nothing, holds a pool slot and keeps its row locks, because "row-level locks are released at transaction end or during savepoint rollback" ([explicit locking](https://www.postgresql.org/docs/18/explicit-locking.html)). The bad example catches the app's connection in that state between its INSERTs. Any work inside the transaction, an HTTP call, a file upload or just application code, adds to the hold time of the connection and of every lock it took. Claim in one autocommit statement, so the claim is committed and the connection is back in the pool before the work starts; the good example asserts the worker's connection is `idle` and holds no transaction while it works. Long transactions also hold back vacuum; see [`pg-transactions-and-locking`](../pg-transactions-and-locking/SKILL.md).

**Rule 3.** With plain `FOR UPDATE` every worker selects the same first pending row, and "a transaction seeking either a table-level or row-level lock will wait indefinitely for conflicting locks to be released" ([explicit locking](https://www.postgresql.org/docs/18/explicit-locking.html)). Workers run one at a time: the naive queue (1 ms of work inside the transaction) stayed at about 335 tps from 4 to 64 connections, with 40 of 64 sessions waiting on locks and latency at 192 ms. "With `SKIP LOCKED`, any selected rows that cannot be immediately locked are skipped", which the docs recommend "to avoid lock contention with multiple consumers accessing a queue-like table" ([SELECT locking clause](https://www.postgresql.org/docs/18/sql-select.html#SQL-FOR-UPDATE-SHARE)). The good variant, with the work after commit, reached 4,994 tps at 16 connections with no session waiting on a lock. In the tests, two sessions claiming at once get jobs 1 and 2 with nothing in `pg_locks` waiting, and with plain `FOR UPDATE` the second session runs into `lock_timeout` (55P03).

**Rule 4.** An `UPDATE` takes a row lock that "block[s] only writers and lockers to the same row" ([explicit locking](https://www.postgresql.org/docs/18/explicit-locking.html)), and it lasts until commit. When every request updates one row, every request waits for the previous one's commit, so connections add waiting, not throughput: one row peaked at 1,671 tps with 4 connections and fell to 1,348 with 64 (12.7 sessions waiting on average). Sixteen shards spread the same writes over 16 rows: 6,681 tps at 16 connections. Reads stay simple and never block, since row locks "do not affect data querying": `SUM(qty)` over the shards. The good example runs 1,000 concurrent sales from two sessions, one transaction each, and the shards add up exactly. Pick the shard with a scalar subquery: `random()` written directly in the `WHERE` clause is evaluated per row and can update zero or several shards. When the value must never go below zero (stock you cannot oversell), a shard can run dry while others still have units; check the shard's `qty` in the `UPDATE` and retry another shard, or use a ledger of movements aggregated by a job.

**Rule 5.** On this 2 vCPU database every good variant was slower at 64 connections than at 16: page 15,047 to 10,665 tps, write 8,464 to 7,600, queue 4,994 to 1,095, counter 6,681 to 6,017, while latency per request rose 4 to 18 times. More connections than the CPUs can serve only queue inside the server. Start small (here the knee was at about 16 connections for 2 vCPU), raise the pool under a realistic load test until throughput stops growing, and stop there. The fleet-wide budget (replicas × processes × pool max) is in [`pg-connections`](../pg-connections/SKILL.md).

**Rule 6.** Pipeline mode "allows applications to send a query without having to read the result of the previously sent query", so "multiple queries/results can be sent/received in a single network transaction", and it "is most useful when the server is distant, i.e., network latency ("ping time") is high, and also when many small operations are being performed in rapid succession" ([libpq pipeline mode](https://www.postgresql.org/docs/18/libpq-pipeline-mode.html)). The API "was introduced in PostgreSQL 14, it is a client-side feature which doesn't require special server support", so it works against any server that speaks the v3 extended query protocol. On an error "the server aborts the current transaction and does not execute any subsequent command in the queue until the next synchronization point", so pipeline statements that belong together and handle the aborted results. `pgbench` exposes it with `\startpipeline` / `\endpipeline` ([pgbench](https://www.postgresql.org/docs/18/pgbench.html)), which is how to measure the gain before changing code. A single statement is still better: it is one round trip and one transaction with no client-side bookkeeping. Driver specifics (for Go, pgx batches) live in the language repositories such as [go-skills](https://github.com/rafapeixer/go-skills).

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
SELECT o.id, o.created_at, i.skus, i.qtys
FROM (SELECT id, created_at FROM orders WHERE customer_id = 7
      ORDER BY created_at DESC, id DESC LIMIT 10) o
LEFT JOIN LATERAL (SELECT array_agg(sku ORDER BY sku) AS skus, array_agg(qty ORDER BY sku) AS qtys
                   FROM order_items WHERE order_id = o.id) i ON true
ORDER BY o.created_at DESC, o.id DESC
```

```sql
WITH o AS (
  INSERT INTO orders (customer_id, status, total) VALUES (7, 'new', 30.00) RETURNING id
)
INSERT INTO order_items (order_id, sku, qty)
SELECT o.id, v.sku, v.qty FROM o, (VALUES ('A1', 1), ('B1', 2), ('C1', 3)) AS v(sku, qty)
RETURNING order_id
```

```sql
UPDATE jobs SET status = 'running', claimed_at = now()
WHERE id = (SELECT id FROM jobs WHERE status = 'pending'
            ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING id
```

```sql
UPDATE stock_shards SET qty = qty - 1
WHERE sku = 'SKU-1' AND shard = (SELECT floor(random() * 16)::int);
SELECT assert_true((SELECT sum(qty) FROM stock_shards WHERE sku = 'SKU-1') = 14997, 'the shards add up to 16,000 minus 1,003 sales');
```

A second session opened with `dblink`, under its own role, plays the application, and `pg_stat_statements` (with `track = 'all'`) counts its statements. The test asserts that: the page with its items is 1 statement returning 10 orders with 3 items each; the order with 3 items is 1 statement, and a duplicate item fails it without leaving an order row; two workers claiming at once get jobs 1 and 2 under a 200 ms `lock_timeout` with no ungranted lock in `pg_locks`; after an autocommit claim the worker's connection is `idle` with no open transaction; a sale holding shard 0 does not block a sale on shard 1 or a `SUM` read; and 1,000 sales from two concurrent sessions leave the 16 shards summing exactly to 16,000 minus every sale.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: one query per order. 10 orders cost 11 round trips; at 0.5 ms
-- each the connection is held for 5.5 ms of network alone, and the
-- benchmark's naive page got 146 tps per connection against 1,473.
PERFORM * FROM dblink('app', format('SELECT sku, qty FROM order_items WHERE order_id = %s', o.id)) AS t(sku text, qty int);
```

```sql
-- MISTAKE: BEGIN + 4 INSERTs + COMMIT is 6 round trips for what one
-- WITH ... INSERT ... RETURNING statement does in 1.
SELECT assert_true(round_trips() = 6, 'the order and its 3 items cost 6 round trips');
```

```sql
-- MISTAKE: no SKIP LOCKED, and the job runs before COMMIT: every other
-- worker waits on this row for as long as the job takes.
SELECT id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE
SELECT assert_error($q$SELECT id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE$q$, '55P03', 'worker 2 waits on the row worker 1 is working on');
```

```sql
-- MISTAKE: one row for every request. The row lock lasts until the sale
-- commits, so concurrent sales run one at a time; in the benchmark this row
-- peaked at 1,671 tps with 4 connections and fell to 1,348 with 64.
SELECT assert_error($q$UPDATE stock SET qty = qty - 1 WHERE sku = 'SKU-1'$q$, '55P03', 'a second sale waits for the first to commit');
```

The assertions describe the cost: the N+1 page is 11 statements from the application session; the order written with `BEGIN`, 4 INSERTs and `COMMIT` is 6, with the connection `idle in transaction` between them; a second worker's plain `FOR UPDATE` on the same queue row and a second sale's `UPDATE` of the hot row both wait until a 200 ms `lock_timeout` raises 55P03 (the timeout exists only so the test does not hang; in production they wait for the other transaction to commit).

## Checklist

When reviewing a request path under this skill, confirm:

- [ ] Do you know how many statements each hot endpoint sends, from `pg_stat_statements` calls per request or a driver trace, and is it 1 wherever the data allows?
- [ ] Does no code path run a query per row of a result (page and children come back through `LEFT JOIN LATERAL`)?
- [ ] Are a parent and its children written by one `WITH ... INSERT ... RETURNING` (or one `unnest` insert) instead of `BEGIN`, N statements and `COMMIT`?
- [ ] Is there no HTTP call, file I/O or job work while a connection is checked out with an open transaction?
- [ ] Does every queue consumer claim with `FOR UPDATE SKIP LOCKED` in one statement and commit before it works?
- [ ] Does no row get updated by every request (global counters, totals, "last seen" rows), or is it sharded or turned into a ledger?
- [ ] Is a sharded counter's shard picked once per statement (scalar subquery or parameter), not with `random()` evaluated per row?
- [ ] Was the pool size chosen from a load test that found the knee, and does the fleet total fit [`pg-connections`](../pg-connections/SKILL.md)?
- [ ] Where several independent statements remain, are they pipelined or batched instead of sent one result at a time?

## When not to apply

- A transaction that must read, decide and write under a lock (check a balance, then debit it) needs several statements; keep them, but send them back to back with no work in between, or move the decision into one `UPDATE ... WHERE balance >= $1 RETURNING`.
- A single LATERAL statement is wrong when the children are unbounded or huge (all events of a customer); page the children separately, as [`pg-query-patterns`](../pg-query-patterns/SKILL.md) says.
- A counter read far more often than it is written (a setting, a feature flag) gains nothing from shards and makes every read a `SUM`; shard only rows that many requests write per second.
- A strict FIFO queue, where job 2 must not start before job 1, cannot use `SKIP LOCKED`; it is serial by definition, so use one consumer and keep its transaction short.
- Benchmarks on a laptop with no added latency hide round-trip cost; measure with the network latency your application really has (this benchmark added 0.5 ms) before deciding a request's shape does not matter.
