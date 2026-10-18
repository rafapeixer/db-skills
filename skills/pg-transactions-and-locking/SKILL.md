---
name: pg-transactions-and-locking
description: Use when writing or reviewing PostgreSQL code that opens transactions, picks an isolation level, locks rows or tables, builds a work queue, uses advisory locks, or sets statement, lock, idle or transaction timeouts. Covers short transactions with no network calls inside, READ COMMITTED vs REPEATABLE READ/SERIALIZABLE with whole-transaction retry on 40001, FOR UPDATE SKIP LOCKED queues, NOWAIT and lock_timeout, per-role timeouts, and transaction-scoped advisory locks behind poolers.
metadata:
  verified: 2026-10-18
---

# Transactions and locking

## The decision

Every write runs in a transaction, so the real decision is how long the transaction lives, what isolation level it uses, which locks it takes and how long anything is allowed to wait for them. By default PostgreSQL never gives up: with no deadlock, "a transaction seeking either a table-level or row-level lock will wait indefinitely for conflicting locks to be released" ([explicit locking](https://www.postgresql.org/docs/18/explicit-locking.html)), and every timeout is 0, disabled ([client connection defaults](https://www.postgresql.org/docs/18/runtime-config-client.html)). One transaction left open across an HTTP call holds its row locks, blocks every worker that touches those rows, and keeps VACUUM from removing dead rows in the whole database. The bad example shows all three: a blocked worker, 500 dead rows that VACUUM cannot remove, and a lost update from retrying the wrong thing.

## The rule

1. Keep transactions short: do the reads, decisions and writes, then COMMIT, and never make a network call or wait for a user between BEGIN and COMMIT.
2. Use READ COMMITTED by default, and choose REPEATABLE READ or SERIALIZABLE only on purpose, with a retry of the whole transaction on SQLSTATE 40001 (and usually 40P01).
3. Claim work from a queue table with `SELECT ... FOR UPDATE SKIP LOCKED LIMIT n`, never with plain `FOR UPDATE`.
4. Never wait for a lock without a limit: use `NOWAIT` when you would rather fail at once, and `lock_timeout` everywhere else.
5. Set `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout` and, on PG 17+, `transaction_timeout` on the application role with `ALTER ROLE ... SET`, and tighten them per transaction with `SET LOCAL`.
6. Use transaction-scoped advisory locks (`pg_advisory_xact_lock`), never session-scoped ones, whenever connections go through PgBouncer or RDS Proxy.
7. Lock rows in a consistent order (`ORDER BY id FOR UPDATE`) so concurrent transactions cannot deadlock.

## Why

**Rule 1.** Locks taken by a transaction are held until it ends. The docs spell out the consequence: since lock waits are indefinite, "it is a bad idea for applications to hold transactions open for long periods of time (e.g., while waiting for user input)" ([explicit locking](https://www.postgresql.org/docs/18/explicit-locking.html)). Locks are only half the cost: "an open transaction prevents vacuuming away recently-dead tuples that may be visible only to this transaction; so remaining idle for a long time can contribute to table bloat" ([idle_in_transaction_session_timeout](https://www.postgresql.org/docs/18/runtime-config-client.html)). In the bad example, worker 1 updates one row and goes idle; the 500 rows another session deletes afterwards survive `VACUUM` (`pgstattuple` counts them as dead) and disappear on the next `VACUUM` once worker 1 commits. Call the API before BEGIN or after COMMIT. If the call must succeed for the write to count, record the intent in one transaction and finish it in another (an outbox row).

**Rule 2.** "Read Committed is the default isolation level in PostgreSQL" ([transaction isolation](https://www.postgresql.org/docs/18/transaction-iso.html)). REPEATABLE READ and SERIALIZABLE protect against anomalies by failing: when a REPEATABLE READ transaction updates a row a concurrent transaction changed and committed, it gets `could not serialize access due to concurrent update`, SQLSTATE 40001. The docs are explicit about what to do next: retry `serialization_failure` unconditionally; "It may also be advisable to retry deadlock failures" (40P01); and "It is important to retry the complete transaction, including all logic that decides which SQL to issue and/or which values to use. Therefore, PostgreSQL does not offer an automatic retry facility" ([serialization failure handling](https://www.postgresql.org/docs/18/mvcc-serialization-failure-handling.html)). Several attempts may be needed under contention, so bound the loop and back off. Re-sending only the failed statement with the old value is the lost update the isolation level was meant to prevent: the bad example ends at balance 110 instead of 160. Retry 23505 and 23P01 only when you know the conflict is transient; the same page warns they "might represent persistent error conditions". Declare read-only transactions `READ ONLY`: under REPEATABLE READ "read-only transactions will never have serialization conflicts".

**Rule 3.** With `SKIP LOCKED`, "any selected rows that cannot be immediately locked are skipped". The docs call the result "an inconsistent view of the data, so this is not suitable for general purpose work, but can be used to avoid lock contention with multiple consumers accessing a queue-like table" ([SELECT locking clause](https://www.postgresql.org/docs/18/sql-select.html#SQL-FOR-UPDATE-SHARE)). In the good example, worker 2 claims jobs 11 to 20 while worker 1 still holds 1 to 10; with plain `FOR UPDATE` (bad example) worker 2 waits on job 1 until worker 1 finishes.

**Rule 4.** "With `NOWAIT`, the statement reports an error, rather than waiting, if a selected row cannot be locked immediately" (SQLSTATE 55P03). `NOWAIT` and `SKIP LOCKED` cover only the row locks of that `SELECT`; the table-level lock "is still taken in the ordinary way" ([SELECT](https://www.postgresql.org/docs/18/sql-select.html#SQL-FOR-UPDATE-SHARE)). `lock_timeout` covers everything else: it applies "both to explicit locking requests ... and to implicitly-acquired locks", such as the row lock an `UPDATE` takes, and the limit "applies separately to each lock acquisition attempt" ([lock_timeout](https://www.postgresql.org/docs/18/runtime-config-client.html)). Both raise 55P03, which the good example asserts against a row held by another session. Treat 55P03 as "busy, try later", not as a bug.

**Rule 5.** The docs say setting `statement_timeout`, `lock_timeout` and `transaction_timeout` in `postgresql.conf` "is not recommended because it would affect all sessions" ([client connection defaults](https://www.postgresql.org/docs/18/runtime-config-client.html)); the role is the right scope, because migrations, batch jobs and humans use other roles. `ALTER ROLE ... SET` makes the value the session default whenever the role starts a new session ([ALTER ROLE](https://www.postgresql.org/docs/18/sql-alterrole.html)), so it applies to every server connection a pooler opens as that role, whereas PgBouncer in transaction mode "Never" supports `SET`/`RESET` ([PgBouncer features](https://www.pgbouncer.org/features.html)). `SET LOCAL` ends with the transaction (the good example checks that `lock_timeout` is back to 0 after COMMIT), and a transaction pooler keeps one server connection for the whole transaction, so it does not leak to the next client. RDS Proxy is stricter: for PostgreSQL it lists "Using `SET` commands" as a cause of pinning, and its `SET LOCAL` exemption is documented only for MySQL ([RDS Proxy pinning](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-pinning.html)), so behind RDS Proxy rely on the role settings (or the proxy's initialization query) and keep `SET LOCAL` for the rare transaction that needs a different limit. What each one does:

| Setting | On expiry | Default |
|---|---|---|
| `statement_timeout` | cancels the statement (57014) | 0, off |
| `lock_timeout` | cancels a statement waiting for a lock (55P03) | 0, off |
| `idle_in_transaction_session_timeout` | terminates the session | 0, off |
| `transaction_timeout` (PG 17+) | terminates the session, idle or busy | 0, off |

`lock_timeout` is "rather pointless" at or above `statement_timeout`, and when `transaction_timeout` is shorter than or equal to the other two, "the longer timeout is ignored" ([client connection defaults](https://www.postgresql.org/docs/18/runtime-config-client.html)). Keep them ordered: lock < statement < transaction. No official source prescribes values, so the numbers are a judgement call; the example uses 5 s, 30 s, 60 s idle and 2 min per transaction as a starting point for an OLTP role. The idle and transaction timeouts terminate the session, which rolls the transaction back and releases its locks and snapshot (the good example asserts the backend is gone and its update undone); your driver sees a closed connection and the pool replaces it. PgBouncer 1.25 adds its own `transaction_timeout` ([changelog](https://www.pgbouncer.org/changelog.html)).

**Rule 6.** A session-level advisory lock "is held until explicitly released or the session ends", and does "not honor transaction semantics": rolling back the transaction keeps the lock. Transaction-level ones "are automatically released at the end of the transaction" ([advisory locks](https://www.postgresql.org/docs/18/explicit-locking.html#ADVISORY-LOCKS)). PgBouncer transaction pooling "Never" supports session advisory locks ([PgBouncer features](https://www.pgbouncer.org/features.html)): the server connection goes back to the pool still holding the lock. RDS Proxy pins the client to its connection on `pg_advisory_lock` and `pg_try_advisory_lock`, but not on `pg_advisory_xact_lock` and its variants ([RDS Proxy pinning](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-pinning.html)), so session locks also cost you connection multiplexing.

**Rule 7.** "The best defense against deadlocks is generally to avoid them by being certain that all applications using a database acquire locks on multiple objects in a consistent order", and to take "the most restrictive mode that will be needed" first ([explicit locking](https://www.postgresql.org/docs/18/explicit-locking.html)). PostgreSQL resolves a deadlock by aborting one transaction, and which one "is difficult to predict". That abort is 40P01, handled by the same whole-transaction retry as rule 2.

The cost: short transactions push work out of the database transaction into application code (outbox rows, idempotency keys, compensating steps), and higher isolation levels push retry loops into every caller. Both are cheaper than a fleet of workers stuck behind one idle connection.

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
BEGIN;
SET LOCAL lock_timeout = '200ms';
WITH next AS (
  SELECT id FROM jobs
  WHERE status = 'queued'
  ORDER BY id
  LIMIT 10
  FOR UPDATE SKIP LOCKED
), claimed AS (
  UPDATE jobs SET status = 'running'
  FROM next WHERE jobs.id = next.id
  RETURNING jobs.id
)
INSERT INTO claimed_by_worker2 SELECT id FROM claimed;
SELECT assert_error('SELECT id FROM jobs WHERE id = 1 FOR UPDATE NOWAIT', '55P03', 'NOWAIT raises lock_not_available on a held row');
COMMIT;
```

```sql
-- Attempt 2 starts over: new snapshot, re-read, recompute, write.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance AS seen FROM accounts WHERE id = 1 \gset
UPDATE accounts SET balance = :seen + 10 WHERE id = 1;
COMMIT;
```

```sql
ALTER ROLE txlock_app SET statement_timeout = '30s';
ALTER ROLE txlock_app SET lock_timeout = '5s';
ALTER ROLE txlock_app SET idle_in_transaction_session_timeout = '60s';
EXECUTE $q$ALTER ROLE txlock_app SET transaction_timeout = '2min'$q$;
```

The test opens a second session with `dblink` and asserts that: worker 2 claims 10 different jobs while worker 1 holds its 10; `NOWAIT` and `lock_timeout` both raise 55P03 against worker 1's row; `SET LOCAL` is gone after COMMIT; a REPEATABLE READ update that races a concurrent deposit raises 40001 and the retried transaction ends at 160, keeping both writes; `pg_advisory_xact_lock` leaves nothing in `pg_locks` after COMMIT; `statement_timeout` cancels a 2 s statement; a new connection as the role picks up all role timeouts (`transaction_timeout` only on PG 17+); and `idle_in_transaction_session_timeout` and, on PG 17+, `transaction_timeout` terminate a session that left a transaction open, rolling back its update.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
SELECT dblink_exec('worker1', 'BEGIN');
SELECT dblink_exec('worker1', $$UPDATE jobs SET status = 'running' WHERE id = 1$$);
-- MISTAKE: the transaction stays open while the application waits on the
-- network. The row lock and the transaction ID are held for as long as the
-- API takes, and no timeout on the role ends it.
-- MISTAKE: no SKIP LOCKED, so every worker queues behind the oldest claimed row.
SELECT assert_error($$SELECT id FROM jobs WHERE status = 'queued' ORDER BY id LIMIT 10 FOR UPDATE$$, '55P03', 'second worker blocks on the first worker''s row');
-- MISTAKE: 500 dead rows survive VACUUM because worker 1's transaction began first.
SELECT assert_true((SELECT dead_tuple_count FROM pgstattuple('jobs')) >= 500, 'dead rows not removable while worker 1 is open');
```

```sql
-- MISTAKE: the "retry" re-sends the same UPDATE with the value read in the
-- failed attempt instead of re-running the whole transaction. The 50 deposit is lost.
UPDATE accounts SET balance = :seen + 10 WHERE id = 1;
-- MISTAKE: pg_advisory_lock is session-scoped; COMMIT does not release it.
SELECT pg_advisory_lock(42);
COMMIT;
```

The assertions describe the damage: worker 1 is `idle in transaction`; worker 2's plain `FOR UPDATE` waits on worker 1's row (asserted by a 200 ms `lock_timeout` that exists only so the test does not hang); 500 deleted rows survive `VACUUM` until worker 1 commits; the statement-only retry leaves the balance at 110, losing the 50 deposit; and the advisory lock is still in `pg_locks` after COMMIT, so another session's `pg_try_advisory_lock(42)` returns false.

## Checklist

When reviewing transactions and locking under this skill, confirm:

- [ ] Is there no HTTP call, queue publish, file upload or user wait between BEGIN and COMMIT?
- [ ] Does every REPEATABLE READ or SERIALIZABLE transaction run inside a bounded retry loop that re-runs the whole transaction function on SQLSTATE 40001 (and 40P01), keyed on the code, not the message?
- [ ] Does every queue consumer claim rows with `FOR UPDATE SKIP LOCKED` and a `LIMIT`?
- [ ] Does every explicit lock (`FOR UPDATE`, `LOCK TABLE`) either use `NOWAIT` or run under a non-zero `lock_timeout`?
- [ ] Does the application role have `statement_timeout`, `lock_timeout` and `idle_in_transaction_session_timeout` set with `ALTER ROLE ... SET` (plus `transaction_timeout` on PG 17+), ordered lock < statement < transaction?
- [ ] Are per-request overrides done with `SET LOCAL` inside the transaction, never with session `SET` through a pooler?
- [ ] Behind PgBouncer or RDS Proxy, are all advisory locks `pg_advisory_xact_lock` / `pg_try_advisory_xact_lock`?
- [ ] Do transactions that lock several rows lock them in the same order (`ORDER BY` the key)?
- [ ] Is anything alerting on the oldest open transaction (`xact_start` and `backend_xmin` in `pg_stat_activity`)?

## When not to apply

- Migrations and maintenance run as a different role, where a 30 s `statement_timeout` would cancel a legitimate index build or backfill. Give that role its own limits, but keep a short `lock_timeout` on DDL so a blocked `ALTER TABLE` does not queue every query behind it.
- Reports and exports that need one consistent snapshot over many statements: use `BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY`, which never raises serialization failures, and run them on a replica or under a role with a longer `transaction_timeout`, since they still hold back vacuum while open.
- A singleton job (one scheduler, one leader) on a direct, unpooled connection may hold a session advisory lock for the life of the process on purpose. Use a dedicated connection that bypasses the pooler, and check `pg_try_advisory_lock`'s result.
- `SKIP LOCKED` is wrong when the reader must see every matching row, such as totals or uniqueness checks; it hides rows by design.
