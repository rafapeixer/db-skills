---
name: mysql-throughput-per-connection
description: Use when you need more throughput from MySQL, see Too many connections, slow requests under load, lock waits or deadlocks, or want to scale the database without a bigger instance. Key rule: connections needed = requests/s x time each request holds one, so make each page one statement (LATERAL + JSON_ARRAYAGG), let one commit cover many rows instead of relaxing sync_binlog or innodb_flush_log_at_trx_commit, claim queue jobs with SKIP LOCKED under READ COMMITTED and work after COMMIT, shard hot counters with the shard picked in the client, and keep the pool small (16 beat 64 on 2 vCPU).
metadata:
  verified: 2026-10-18
---

# Throughput per connection

## The decision

How many requests per second each MySQL connection can serve. It comes up when a service needs more volume, when the fleet hits `Too many connections`, or when latency climbs under load while the database CPU looks fine. Little's law sets the arithmetic: connections busy = requests per second × time each request holds a connection. At 1,000 req/s, a request that holds its connection for 7.26 ms keeps about 7 connections busy; one that holds it for 0.78 ms keeps less than 1. Hold time is rarely the SQL itself. It is network round trips (each statement waits a full round trip for its result), commits (each one waits for the redo log and the binary log to reach disk), and lock waits (a connection queued behind another transaction's row or gap lock does nothing). This skill cuts all three, so the same instance serves more volume with fewer connections. How to shape each query lives in [`mysql-query-patterns`](../mysql-query-patterns/SKILL.md), isolation, lock and timeout rules in [`mysql-transactions-and-locking`](../mysql-transactions-and-locking/SKILL.md), and the connection budget in [`mysql-connections`](../mysql-connections/SKILL.md).

## The rule

1. Count the statements of every request and return a page and its children in one statement, a `LEFT JOIN LATERAL` derived table with `JSON_ARRAYAGG` (MySQL 8.0.14+), never one query per row of the page.
2. Let one commit cover many rows: put the writes of one request in one transaction and many rows in one multi-row `INSERT`, and never buy speed by relaxing `innodb_flush_log_at_trx_commit` or `sync_binlog` from 1.
3. Claim queue work with `SELECT ... FOR UPDATE SKIP LOCKED` in a session running under READ COMMITTED, then commit before doing the work.
4. Never have every request update the same row: shard a hot counter into N rows, pick the shard in the client and bind it (or compute it once in a `NO_MERGE` derived table), and `SUM` to read.
5. Keep the pool small and find the knee by measuring: past it, more connections lower throughput, and on a 2 vCPU instance 16 beat 64 for the page and the queue.
6. Never hold a connection or an open transaction across work that is not database work: claim or write, commit, release the connection, then do the work.

## Why

The numbers below come from this repository's benchmark, [`benchmarks/throughput/mysql/`](../../benchmarks/throughput/mysql/): MySQL 8.4 limited to 2 vCPU and 1 GiB like an RDS db.t4g.micro, all durability and isolation settings at their defaults (REPEATABLE READ, binary log on, `sync_binlog=1`, `innodb_flush_log_at_trx_commit=1`), sysbench from a client with 0.5 ms of network round trip added with `netem`, 20 s per point, results in `results.csv`. The schema is indexed the same way for both variants, so the only difference is how the request talks to the database.

| Scenario | Variant | 4 conns | 16 conns | 64 conns | Latency at 4 |
|---|---|---|---|---|---|
| Page with items | N+1, 11 round trips | 551 tps | 1,743 tps | 1,426 tps | 7.26 ms |
| Page with items | one `LATERAL` statement | 5,108 tps | 7,477 tps | 5,741 tps | 0.78 ms |
| Order with 3 items | `BEGIN` + 4 INSERTs + `COMMIT` | 613 tps | 1,945 tps | 2,595 tps | 6.52 ms |
| Order with 3 items | `BEGIN` + 2 INSERTs + `COMMIT` | 665 tps | 2,330 tps | 3,256 tps | 6.01 ms |
| Queue claim | `FOR UPDATE`, work inside | 218 tps | 214 tps | 96 tps | 18.3 ms |
| Queue claim | `SKIP LOCKED`, work after commit | 625 tps | 1,937 tps | 284 tps | 6.40 ms |
| Hot counter | one row | 518 tps | 519 tps | 513 tps | 7.72 ms |
| Hot counter | 16 shards | 919 tps | 2,197 tps | 3,113 tps | 4.35 ms |

**Rule 1.** Each statement waits for its result before the next one goes out, so a request costs at least its round trips × RTT, and the connection is held for all of it. The N+1 page served 138 requests/s per connection at 4 connections; the `LATERAL` page served 1,277, nine times more. With 4 connections the one-statement page (5,108 tps) serves 2.9 times the N+1 page's best (1,743 tps at 16): no pool size rescues an N+1. A derived table "cannot normally refer to (depend on) columns of preceding tables in the same FROM clause. As of MySQL 8.0.14, a derived table may be defined as a lateral derived table to specify that such references are permitted" ([lateral derived tables](https://dev.mysql.com/doc/refman/8.0/en/lateral-derived-tables.html)). The good example's plan reads the page through `orders_customer_created` and each order's items through the `order_items` primary key, and `performance_schema.events_statements_summary_by_digest` counts 1 statement for the page; the bad example's page is 1 query for the orders plus 10 item queries, each a fast primary key lookup. The correlated `COALESCE((SELECT JSON_ARRAYAGG(...)), JSON_ARRAY())` form in [`mysql-query-patterns`](../mysql-query-patterns/SKILL.md) is also one statement; use either. `JSON_ARRAYAGG` "Returns `NULL` if the result contains no rows" ([aggregate functions](https://dev.mysql.com/doc/refman/8.4/en/aggregate-functions.html#function_json-arrayagg)), so an order with no items comes back with `items` NULL from the `LEFT JOIN LATERAL`; handle it in the query (`COALESCE`) or the client.

**Rule 2.** "InnoDB must flush the log to disk at each transaction commit if that transaction made modifications to the database. When each change is followed by a commit (as with the default autocommit setting), the I/O throughput of the storage device puts a cap on the number of potential operations per second"; the manual's advice is to "wrap several related data change operations into a single transaction" ([InnoDB transaction management](https://dev.mysql.com/doc/refman/8.4/en/optimizing-innodb-transaction-management.html)). With the binary log on, `sync_binlog=1` also "Enables synchronization of the binary log to disk before transactions are committed" ([binary logging options](https://dev.mysql.com/doc/refman/8.4/en/replication-options-binary-log.html#sysvar_sync_binlog)). On the benchmark host one connection doing single-row autocommit `UPDATE`s averaged 2.68 ms, of which 0.5 ms is network: the commit, not the round trip, was most of the cost. That is why cutting the order from 6 round trips to 4 (one multi-row `INSERT` for the 3 items) gained only 8% at 4 connections and 25% at 64, and why write throughput still rose at 64 connections, where concurrent commits share flushes. MySQL has no `INSERT ... RETURNING`, so the order and its items stay two statements, joined on the server by `LAST_INSERT_ID()`, inside one transaction. The examples measure the commit cost directly with `Innodb_os_log_fsyncs`: 200 single-row `INSERT`s in autocommit cost at least 200 redo log fsyncs; the same 200 `INSERT`s in one transaction, plus the order, cost a handful (1 to 4 on 8.4 and 9.7).

Do not get the speed back by relaxing durability. "The default setting of 1 is required for full ACID compliance"; with 0 or 2, logs are flushed once per second and "Transactions for which logs have not been flushed can be lost in a crash" ([innodb_flush_log_at_trx_commit](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html#sysvar_innodb_flush_log_at_trx_commit)). With `sync_binlog=0` or `N`, "in the event of a power failure or operating system crash, it is possible that the server has committed transactions that have not been synchronized to the binary log", the record that replicas apply and that recovery replays after a restore ([binary log](https://dev.mysql.com/doc/refman/8.4/en/binary-log.html)); "For the greatest possible durability and consistency in a replication setup that uses InnoDB with transactions", the manual says to use `sync_binlog=1` and `innodb_flush_log_at_trx_commit=1` ([sync_binlog](https://dev.mysql.com/doc/refman/8.4/en/replication-options-binary-log.html#sysvar_sync_binlog)). The good example asserts both are still 1. Fewer, larger transactions are the safe lever; keep each one short (rule 6) and bounded, since the same page warns that rolling back a huge transaction can take "several times as long" as the changes.

**Rule 3.** With plain `FOR UPDATE` every worker selects the same first pending row and waits for it. The naive queue (1 ms of work inside the transaction) stayed at about 215 claims/s at 4 and 16 connections and fell to 96 at 64, with 35 of 64 transactions waiting on locks. "A locking read that uses SKIP LOCKED never waits to acquire a row lock. The query executes immediately, removing locked rows from the result set", and while that makes it "not suitable for general transactional work", it "may be used to avoid lock contention when multiple sessions access the same queue-like table" ([locking reads](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking-reads.html)). With the work after commit it reached 1,937 claims/s at 16 connections with no lock waits. `SKIP LOCKED` alone is not enough under the default REPEATABLE READ: the claim scans the `(status, id)` index and takes a next-key lock, "a combination of a record lock on the index record and a gap lock on the gap before the index record" ([InnoDB locking](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking.html)). Moving the job to `'done'` inserts a new `(status, id)` entry into a gap another claimer holds, which needs an insert intention lock, "a type of gap lock set by INSERT operations prior to row insertion". In the bad example worker 2 gets job 2 at once, then its `UPDATE` waits on `X,GAP,INSERT_INTENTION` until worker 1 commits. In the benchmark, REPEATABLE READ cut the `SKIP LOCKED` queue to 351, 328 and 5 claims/s at 4, 16 and 64 connections, with 310 to 1,504 deadlocks per second. Under READ COMMITTED, InnoDB "locks only index records, not the gaps before them, and thus permits the free insertion of new records next to locked records" ([isolation levels](https://dev.mysql.com/doc/refman/8.4/en/innodb-transaction-isolation-levels.html)); in the good example worker 2 claims and commits job 2 while worker 1's claim is still open. Set it for the queue session only, with the trade-offs in [`mysql-transactions-and-locking`](../mysql-transactions-and-locking/SKILL.md) (row-based binary logging, no repeatable reads). MySQL has no `UPDATE ... RETURNING`, so the claim is a locking `SELECT` and an `UPDATE` in one short transaction.

**Rule 4.** Every `UPDATE` of a row holds its lock until commit, so when every request updates one row, every request waits for the previous one's commit, and connections add waiting, not throughput: one row stayed at about 515 updates/s from 4 to 64 connections, with 40.5 transactions waiting at 64. Sixteen shards spread the same writes over 16 rows and reached 3,113 at 64. Reads stay simple and never wait, because a plain `SELECT SUM(qty)` is a consistent read, and "A consistent read does not set any locks on the tables it accesses" ([consistent reads](https://dev.mysql.com/doc/refman/8.4/en/innodb-consistent-read.html)); the good example sells on shard 1 and reads the total while another sale holds shard 0, then runs 1,000 sales from two concurrent sessions and the shards add up exactly. Pick the shard outside the `WHERE` clause. "If a function is tagged nondeterministic, a reference to it in a WHERE clause is evaluated for every row", so `UPDATE t ... WHERE id = FLOOR(1 + RAND() * 49)` "might update zero, one, or multiple rows", and "InnoDB might escalate to a range-key lock rather than taking a single row lock" ([function call optimization](https://dev.mysql.com/doc/refman/8.4/en/function-optimization.html)). Wrapping it in a scalar subquery, `shard = (SELECT FLOOR(RAND() * 16))`, does not help in MySQL: in the bad example on 8.4 and 9.7 about 190 of 300 such sales changed zero or two shards. The manual's two fixes work: compute the value first and pass it in (the benchmark binds a random shard from the client), or assign it "in a derived table" with `/*+ NO_MERGE(dt) */`, which the good example checks over 200 sales. When the value must never go below zero (stock you cannot oversell), a shard can run dry while others still have units; add `AND qty > 0` and retry another shard when `ROW_COUNT()` is 0, or append to a ledger aggregated by a job.

**Rule 5.** On this 2 vCPU database the one-statement page fell from 7,477 tps at 16 connections to 5,741 at 64, and the `SKIP LOCKED` queue from 1,937 to 284 claims/s with no lock waits (the claim `SELECT` averaged 99 ms in a repeat run, stepping over locked and delete-marked index entries while purge fell behind). Write-heavy paths kept rising to 64 here (orders 3,256 tps, sharded counter 3,113) because concurrent commits share flushes, but latency per request grew from 4.35 ms to 20.5 ms for the counter. Community MySQL gives each connection its own thread ("there are as many threads as there are clients currently connected", [connection interfaces](https://dev.mysql.com/doc/refman/8.4/en/connection-interfaces.html)), so connections past what the CPUs and disk can serve only queue inside the server. Start small (16 for 2 vCPU here), raise the pool under a realistic load test of your own mix until throughput stops growing, and stop there. The fleet-wide budget (replicas × processes × pool max) is in [`mysql-connections`](../mysql-connections/SKILL.md).

**Rule 6.** "All locks set by FOR SHARE and FOR UPDATE queries are released when the transaction is committed or rolled back" ([locking reads](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking-reads.html)), so any work done inside the transaction, an HTTP call, a file upload or just application code, adds to the hold time of the connection and of every lock it took. In the benchmark the naive queue, with 1 ms of work inside the transaction, had 18.3 ms of latency at 4 connections against 6.40 ms for claim, commit, then work. The good example asserts that worker 2 has no open transaction in `information_schema.innodb_trx` while it works; in the bad example worker 1 holds its transaction and row locks while it works, and worker 2's plain `FOR UPDATE` waits until a 1 s `innodb_lock_wait_timeout` raises 1205. Long transactions also hold back purge; see [`mysql-transactions-and-locking`](../mysql-transactions-and-locking/SKILL.md).

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
SELECT o.id, o.total, o.created_at, i.items
FROM (SELECT id, total, created_at FROM orders WHERE customer_id = 7
      ORDER BY created_at DESC, id DESC LIMIT 10) AS o
LEFT JOIN LATERAL (SELECT JSON_ARRAYAGG(JSON_OBJECT('sku', sku, 'qty', qty)) AS items
                   FROM order_items WHERE order_id = o.id) AS i ON TRUE
ORDER BY o.created_at DESC, o.id DESC;
```

```sql
START TRANSACTION;
INSERT INTO orders (customer_id, total, created_at) VALUES (7, 30.00, NOW(6));
INSERT INTO order_items (order_id, sku, qty) VALUES
  (LAST_INSERT_ID(), 'A1', 1), (LAST_INSERT_ID(), 'B1', 2), (LAST_INSERT_ID(), 'C1', 3);
COMMIT;
```

```sql
SET SESSION transaction_isolation = 'READ-COMMITTED';
START TRANSACTION;
SELECT id INTO @job FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED;
UPDATE jobs SET status = 'running', claimed_at = NOW(6) WHERE id = @job;
COMMIT;
```

```sql
SET shard_pick = FLOOR(RAND() * 16);
UPDATE stock_shards SET qty = qty - 1 WHERE sku = 'SKU-1' AND shard = shard_pick;
```

Other sessions are events (`SET GLOBAL event_scheduler = ON` and `CREATE EVENT ... ON SCHEDULE AT CURRENT_TIMESTAMP`), each waiting on a `GET_LOCK` user lock that the test holds, so no step depends on timing. The test asserts that: the page uses `orders_customer_created` and the `order_items` primary key, returns 10 orders with 3 items each, and is 1 statement in `events_statements_summary_by_digest`, with no per-order item query; `innodb_flush_log_at_trx_commit`, `sync_binlog` and `log_bin` are 1, and an order plus 200 sale lines in two transactions cost at most 20 redo log fsyncs; under READ COMMITTED, worker 2 claims and commits job 2 while worker 1's claim of job 1 is still open, and holds no transaction while it works; a sale holding shard 0 blocks neither a sale on shard 1 nor the `SUM`; 1,000 sales from two concurrent sessions each change exactly one shard and the total is exact; and 200 one-statement sales with the shard in a `NO_MERGE` derived table each change exactly one shard.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: one query per order. 10 orders cost 11 round trips; in the
-- benchmark this page served 138 requests/s per connection against 1,277.
SELECT sku, qty FROM order_items WHERE order_id = 19506;
SELECT sku, qty FROM order_items WHERE order_id = 19006;
```

```sql
-- MISTAKE: under REPEATABLE READ the claim takes a next-key lock, which also
-- locks the gap before the row. Moving a job from 'pending' to 'done' inserts
-- into that gap, so worker 2's UPDATE waits for worker 1 to commit.
START TRANSACTION;
SELECT id INTO @job FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED;
UPDATE jobs SET status = 'done', claimed_at = NOW(6) WHERE id = @job;
CALL assert_true(@mode = 'X,GAP,INSERT_INTENTION' AND @index = 'jobs_status_id',
```

```sql
-- MISTAKE: no SKIP LOCKED, so worker 2 queues behind worker 1's row for as
-- long as worker 1's job takes.
CALL assert_errno("SELECT id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE", 1205, 'worker 2 waits on the row worker 1 is working on');
```

```sql
-- MISTAKE: RAND() is evaluated for every row the UPDATE reads, even
-- inside a scalar subquery, so one sale changes zero, one or several shards.
UPDATE stock_shards SET qty = qty - 1 WHERE sku = 'SKU-1' AND shard = (SELECT FLOOR(RAND() * 16));
```

The assertions describe the cost: the N+1 page is 11 statements by digest (1 for the orders, 10 for the items); 200 single-row `INSERT`s in autocommit cost at least 200 redo log fsyncs; under REPEATABLE READ, worker 2's `SKIP LOCKED` claim gets job 2 but its `UPDATE` waits on an `X,GAP,INSERT_INTENTION` lock in `jobs_status_id` until worker 1 commits; worker 1 holds an open transaction with row locks while it works, and worker 2's plain `FOR UPDATE` and a second sale's `UPDATE` of the hot row both wait until a 1 s `innodb_lock_wait_timeout` raises 1205 (the timeout exists only so the test does not hang; in production they wait up to 50 s); and of 300 sales with `RAND()` in a scalar subquery some change zero or several shards. If any of these stops happening, the example fails.

## Checklist

When reviewing a request path under this skill, confirm:

- [ ] Do you know how many statements each hot endpoint sends (`COUNT_STAR` per digest in `events_statements_summary_by_digest` against requests served, or a driver trace), and is it the minimum the data allows?
- [ ] Does no code path run a query per row of a result (a page and its children come back through `LEFT JOIN LATERAL` or a correlated `JSON_ARRAYAGG` subquery)?
- [ ] Does each request commit once, with its rows in one transaction and multi-row `INSERT`s, instead of one autocommit statement per row?
- [ ] Are `innodb_flush_log_at_trx_commit` and `sync_binlog` still 1 (check the RDS parameter group too), with no "performance" change that trades committed transactions for speed?
- [ ] Is there no HTTP call, file I/O or job work while a connection has an open transaction?
- [ ] Does every queue consumer claim with `FOR UPDATE SKIP LOCKED` in a READ COMMITTED session, in one short transaction, and work after commit?
- [ ] Does no row get updated by every request (global counters, totals, "last seen" rows), or is it sharded or turned into a ledger?
- [ ] Is a sharded counter's shard picked in the client and bound, or in a `NO_MERGE` derived table, never with `RAND()` in the `WHERE` clause or a scalar subquery?
- [ ] Was the pool size chosen from a load test that found the knee, and does the fleet total fit [`mysql-connections`](../mysql-connections/SKILL.md)?

## When not to apply

- A transaction that must read, decide and write under a lock (check a balance, then debit it) needs several statements; keep them, but send them back to back with no work in between, or move the decision into one `UPDATE ... SET balance = balance - ? WHERE id = ? AND balance >= ?` and check `ROW_COUNT()`.
- A single `LATERAL` statement is wrong when the children are unbounded or huge (all events of a customer); page the children separately, as [`mysql-query-patterns`](../mysql-query-patterns/SKILL.md) says.
- Grouping rows into one transaction has a limit: a bulk load of millions of rows in one transaction holds its locks and undo for the whole load and is slow to roll back; commit in bounded batches of a few thousand rows.
- A counter read far more often than it is written (a setting, a feature flag) gains nothing from shards and makes every read a `SUM`; shard only rows that many requests write per second.
- A strict FIFO queue, where job 2 must not start before job 1, cannot use `SKIP LOCKED`; it is serial by definition, so use one consumer and keep its transaction short.
- Code that relies on REPEATABLE READ gap locks to stop a concurrent insert, or a server still on statement-based binary logging, cannot move the queue session to READ COMMITTED; see [`mysql-transactions-and-locking`](../mysql-transactions-and-locking/SKILL.md) for what to fix first.
- Benchmarks on a laptop with no added latency and a fast local disk hide both round-trip and commit cost; measure with the network latency and storage your application really has (this benchmark added 0.5 ms and ran on Docker Desktop, not EBS) before deciding a request's shape does not matter.
