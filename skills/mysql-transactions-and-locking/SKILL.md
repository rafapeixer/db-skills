---
name: mysql-transactions-and-locking
description: Use when writing MySQL code with transactions, SELECT ... FOR UPDATE, work queues, isolation levels, money transfers, deadlocks or lock wait timeouts. Key rules: REPEATABLE READ gap locks block inserts, so run hot write paths under READ COMMITTED on purpose; queues use FOR UPDATE SKIP LOCKED; set innodb_lock_wait_timeout per session (default 50 s); after 1205 ROLLBACK the whole transaction, because only the statement was undone; retry the whole transaction on 1213; lock rows in one order.
metadata:
  verified: 2026-10-18
---

# Transactions and locking

## The decision

Every InnoDB write runs in a transaction, so the decision is how long the transaction lives, which isolation level it runs under, which rows and gaps it locks, how long anything waits for those locks, and what the application does when a wait fails. The defaults are built for consistency, not for many concurrent writers: REPEATABLE READ locks the gaps around every range a locking read or `UPDATE` scans, a row lock wait lasts 50 s, a metadata lock wait lasts a year, and a lock wait timeout rolls back only the statement that waited. Get it wrong and an insert for one customer waits on a transaction that touched another, a worker pool queues behind one row, a request commits half a transaction, and an open read view stops purge for the whole server. The bad example shows each of these on MySQL 8.4 and 9.7.

## The rule

1. Keep transactions short and explicit: `START TRANSACTION`, the reads and writes, `COMMIT`, with no network call or user wait inside, and never leave `autocommit = 0` with a read that nobody commits.
2. Know that REPEATABLE READ (the default) takes next-key and gap locks on every range a locking read, `UPDATE` or `DELETE` scans; for contention-heavy OLTP write paths, run them under READ COMMITTED on purpose, accepting non-repeatable reads, phantoms and row-based binary logging.
3. Claim work from a queue table with `SELECT ... FOR UPDATE SKIP LOCKED` and a `LIMIT`, and use `NOWAIT` when you would rather fail at once than wait for a row.
4. Set `innodb_lock_wait_timeout` (row locks, default 50 s) and `lock_wait_timeout` (metadata locks, default one year) per session to a few seconds for request-serving code.
5. After error 1205 (lock wait timeout), `ROLLBACK` the whole transaction before retrying, because InnoDB rolled back only the statement that waited.
6. After error 1213 (deadlock, SQLSTATE 40001), retry the whole transaction, re-reading and recomputing everything, in a bounded loop with backoff.
7. Lock rows in a consistent order (`ORDER BY id FOR UPDATE`, or the same table and key order in every code path) so concurrent transactions queue instead of deadlocking.

## Why

**Rule 1.** "By default, MySQL starts the session for each new connection with autocommit enabled", so each statement is its own transaction; "If autocommit mode is disabled within a session with SET autocommit = 0, the session always has a transaction open" ([autocommit, commit, rollback](https://dev.mysql.com/doc/refman/8.4/en/innodb-autocommit-commit-rollback.html)). Locking reads only exist inside a transaction, and "All locks set by FOR SHARE and FOR UPDATE queries are released when the transaction is committed or rolled back" ([locking reads](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking-reads.html)). The deadlock page says the same: "Keep transactions small and short in duration to make them less prone to collision", and "do not leave an interactive mysql session open for a long time with an uncommitted transaction" ([deadlocks](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlocks-handling.html)). Locks are only half the cost. Under REPEATABLE READ, "the InnoDB multi-version concurrency control (MVCC) system must keep a copy of the data in the undo log until all transactions that depend on that data have completed"; the manual names "Running a SELECT query after disabling autocommit, and forgetting to issue an explicit COMMIT or ROLLBACK" as a cause of a growing history list length, which is "typically a low value, usually less than a few thousand" ([purge configuration](https://dev.mysql.com/doc/refman/8.4/en/innodb-purge-configuration.html)). In the bad example one forgotten `SELECT` under `autocommit = 0` and 1000 single-row updates leave at least 900 entries in `trx_rseg_history_len` that purge cannot remove (`information_schema.innodb_metrics`). Set autocommit explicitly in your pool and use `START TRANSACTION` for multi-statement work.

**Rule 2.** "The default isolation level for InnoDB is REPEATABLE READ." For locking reads, `UPDATE` and `DELETE`, a unique index with a unique search condition locks only the row; "For other search conditions, InnoDB locks the index range scanned, using gap locks or next-key locks to block insertions by other sessions into the gaps covered by the range" ([transaction isolation levels](https://dev.mysql.com/doc/refman/8.4/en/innodb-transaction-isolation-levels.html)). Gap locks are "purely inhibitive": they exist only to stop inserts, and two transactions can hold them on the same gap ([InnoDB locking](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking.html)). In the bad example a `FOR UPDATE` on account 10 through a non-unique index blocks an `INSERT` for account 11, a different customer. Under READ COMMITTED, InnoDB "locks only index records, not the gaps before them", gap locking stays only "for foreign-key constraint checking and duplicate-key checking", and for `UPDATE`/`DELETE` "Record locks for nonmatching rows are released after MySQL has evaluated the WHERE condition. This greatly reduces the probability of deadlocks, but they can still happen" ([transaction isolation levels](https://dev.mysql.com/doc/refman/8.4/en/innodb-transaction-isolation-levels.html)). The good example inserts account 11 while another READ COMMITTED transaction holds account 10, and still times out updating account 10's rows. The trade-offs, from the same page: "phantom row problems may occur", each consistent read sees a fresh snapshot, and "Only row-based binary logging is supported with the READ COMMITTED isolation level" (MIXED switches to row-based). The deadlock page suggests it directly: with locking reads, "try using a lower isolation level such as READ COMMITTED" ([deadlocks](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlocks-handling.html)). Keep REPEATABLE READ for reports that must see one snapshot across statements. Behind RDS Proxy, `SET SESSION transaction_isolation` is tracked without pinning, but setting it for the next transaction only (`SET TRANSACTION ISOLATION LEVEL ...`) pins the connection ([RDS Proxy pinning](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-pinning.html)).

**Rule 3.** "A locking read that uses NOWAIT never waits to acquire a row lock. The query executes immediately, failing with an error if a requested row is locked" (error 3572, SQLSTATE HY000, "Do not wait for lock"); with `SKIP LOCKED` it executes "immediately, removing locked rows from the result set". The manual warns that skipping rows gives "an inconsistent view of the data", so it is "not suitable for general transactional work" but fits "multiple sessions access the same queue-like table". Both apply to row locks only, and both are "unsafe for statement based replication" ([locking reads](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking-reads.html)). In the good example worker 2 claims jobs 11 to 20 while worker 1 holds 1 to 10; with plain `FOR UPDATE` (bad example) worker 2 waits on job 1 until its lock wait timeout. Send the `UPDATE` with the claimed id list: in this test, an `UPDATE ... WHERE id IN (SELECT ... FROM claims)` under REPEATABLE READ took shared next-key locks on the subquery's table and blocked the other worker's insert.

**Rule 4.** `innodb_lock_wait_timeout` is "The length of time in seconds an InnoDB transaction waits for a row lock before giving up. The default value is 50 seconds"; the manual says "You might decrease this value for highly interactive applications or OLTP systems", and "Any client can change the SESSION setting" ([InnoDB parameters](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html#sysvar_innodb_lock_wait_timeout)). It does not cover metadata locks: those wait for `lock_wait_timeout`, whose default is 31536000 s (one year) and which "applies to all statements that use metadata locks", DML and DDL ([server system variables](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_lock_wait_timeout)). The good example sets both to 1 s and asserts error 1205 for a row lock wait and for an `ALTER TABLE` waiting on another transaction's metadata lock. No official source gives a production value; a few seconds, below your request timeout, is a judgement call, and the 1 s in the examples exists only to keep them fast. On RDS Proxy, setting a session variable pins the connection unless you use session pinning filters or put the `SET` in the proxy's initialization query ([RDS Proxy pinning](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-pinning.html)); a parameter group value is the other option.

**Rule 5.** "When a lock wait timeout occurs, the current statement is rolled back (not the entire transaction)"; whole-transaction rollback needs `--innodb-rollback-on-timeout`, which is off by default and not dynamic ([InnoDB parameters](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html#sysvar_innodb_rollback_on_timeout)). The error page adds that "Locks are not released in a rollback of a single SQL statement" ([InnoDB error handling](https://dev.mysql.com/doc/refman/8.4/en/innodb-error-handling.html)). In the bad example the `UPDATE` times out, the transaction is still open, and `COMMIT` persists the audit row for a cancellation that never happened. The good example rolls back and nothing is written.

**Rule 6.** "A transaction deadlock causes InnoDB to roll back the entire transaction. Retry the entire transaction when this happens" ([InnoDB error handling](https://dev.mysql.com/doc/refman/8.4/en/innodb-error-handling.html)). The client sees `ERROR 1213 (40001): Deadlock found when trying to get lock; try restarting transaction` ([deadlock example](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlock-example.html)). InnoDB detects deadlocks at once and "tries to pick small transactions to roll back, where the size of a transaction is determined by the number of rows inserted, updated, or deleted" ([deadlock detection](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlock-detection.html)), so your transaction can be the victim at any time: "Always be prepared to re-issue a transaction if it fails due to deadlock" ([deadlocks](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlocks-handling.html)). In the bad example the deadlock rolls back the debit and the audit row; re-sending only the failed credit creates 20 out of nothing (the balances sum to 220 instead of 200). Key the retry on error number 1213, not the message, and bound it (three to five attempts with jittered backoff is a judgement call). Count deadlocks with `lock_deadlocks` in `information_schema.innodb_metrics`, and read the latest one in `SHOW ENGINE INNODB STATUS`.

**Rule 7.** "When modifying multiple tables within a transaction, or different sets of rows in the same table, do those operations in a consistent order each time. Then transactions form well-defined queues and do not deadlock" ([deadlocks](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlocks-handling.html)). In the good example both transfers lock accounts 1 and 2 with `ORDER BY id FOR UPDATE`: the second one waits until the first commits, both commit, and `lock_deadlocks` does not move. In the bad example the same two transfers lock the accounts in opposite orders and one gets 1213.

The cost: short transactions move work out of the database transaction into application code (outbox rows, idempotency keys), READ COMMITTED gives up repeatable reads inside a transaction, and every caller needs a retry loop. All three are cheaper than requests stuck for 50 s behind one open transaction.

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
SET SESSION innodb_lock_wait_timeout = 1;
SET SESSION lock_wait_timeout = 1;
START TRANSACTION;
SELECT GROUP_CONCAT(id) INTO @ids FROM (
SELECT id FROM jobs WHERE status = 'queued' ORDER BY id LIMIT 10
FOR UPDATE SKIP LOCKED
) AS next;
-- The application gets the ids back and sends the UPDATE with that list.
SET @claim = CONCAT('UPDATE jobs SET status = ''running'', worker = 2 WHERE id IN (', @ids, ')');
CALL assert_errno('SELECT id FROM jobs WHERE id = 1 FOR UPDATE NOWAIT', 3572, 'NOWAIT fails at once on a held row');
COMMIT;
```

```sql
START TRANSACTION;
INSERT INTO audit_log (msg) VALUES ('cancel job 1');
CALL assert_errno("UPDATE jobs SET status = 'cancelled' WHERE id = 1", 1205, 'innodb_lock_wait_timeout bounds the row lock wait');
-- 1205 undid the UPDATE only; ROLLBACK undoes the INSERT too, then retry it all.
ROLLBACK;
```

```sql
SET SESSION transaction_isolation = 'READ-COMMITTED';
SELECT COUNT(*) INTO @n FROM orders WHERE account_id = 10 FOR UPDATE;
INSERT INTO orders (account_id, amount) VALUES (11, 50);
```

```sql
START TRANSACTION;
SELECT id FROM accounts WHERE id IN (1, 2) ORDER BY id FOR UPDATE;
UPDATE accounts SET balance = balance - 20 WHERE id = 2;
UPDATE accounts SET balance = balance + 20 WHERE id = 1;
COMMIT;
```

A second session comes from an event (`SET GLOBAL event_scheduler = ON` and `CREATE EVENT ... ON SCHEDULE AT CURRENT_TIMESTAMP`), which runs in its own connection while the test goes on. The test asserts that: worker 2 claims 10 different jobs, starting at 11, while worker 1 holds its 10; `NOWAIT` fails with error 3572 on worker 1's row; a session `innodb_lock_wait_timeout` of 1 s raises 1205 on an `UPDATE` of that row, and `ROLLBACK` leaves no audit row; a session `lock_wait_timeout` of 1 s raises 1205 on an `ALTER TABLE` waiting for the metadata lock; under READ COMMITTED an insert for account 11 does not wait for a transaction that locked account 10, while account 10's rows stay locked; and two transfers that lock accounts in id order both commit with the right balances and no new deadlock.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: no SKIP LOCKED, so worker 2 queues behind worker 1's rows.
CALL assert_errno("SELECT id FROM jobs WHERE status = 'queued' ORDER BY id LIMIT 10 FOR UPDATE", 1205, 'worker 2 waits on worker 1 rows');
START TRANSACTION;
INSERT INTO audit_log (msg) VALUES ('cancel job 1');
CALL assert_errno("UPDATE jobs SET status = 'cancelled' WHERE id = 1", 1205, 'the UPDATE timed out');
COMMIT;
```

```sql
-- MISTAKE: account 2 first, while the other transaction locks account 1 first.
UPDATE accounts SET balance = balance - 20 WHERE id = 2;
CALL assert_errno('UPDATE accounts SET balance = balance + 20 WHERE id = 1', 1213, 'opposite lock order deadlocks');
-- MISTAKE: the "retry" re-sends only the failed statement. The debit and the
-- audit row were rolled back with the transaction, so 20 appears from nowhere.
UPDATE accounts SET balance = balance + 20 WHERE id = 1;
COMMIT;
```

The assertions describe the damage: the session runs on the defaults (REPEATABLE READ, 50 s row lock wait, one-year metadata lock wait, statement-only rollback on timeout); worker 2's plain `FOR UPDATE` waits on worker 1's rows (the 1 s timeout exists only so the test does not hang for 50 s); after 1205 the transaction is still open and `COMMIT` keeps the audit row of a cancellation that never happened; under REPEATABLE READ a `FOR UPDATE` on account 10 blocks an insert for account 11; the opposite lock order raises 1213, the whole transaction is gone, and the statement-only retry leaves the balances summing to 220 instead of 200; and a `SELECT` left open under `autocommit = 0` keeps at least 900 of 1000 small updates in `trx_rseg_history_len`, where purge cannot remove them.

## Checklist

When reviewing transactions and locking under this skill, confirm:

- [ ] Is there no HTTP call, queue publish, file upload or user wait between `START TRANSACTION` and `COMMIT`?
- [ ] Is autocommit set explicitly in the pool, and does every connection with `autocommit = 0` commit or roll back before it goes back to the pool?
- [ ] For every locking read, `UPDATE` or `DELETE` that scans a range under REPEATABLE READ, is blocking inserts into that range intended, or does the path run under READ COMMITTED with row-based binlog?
- [ ] Does every queue consumer claim rows with `FOR UPDATE SKIP LOCKED` and a `LIMIT`?
- [ ] Does request-serving code set `innodb_lock_wait_timeout` and `lock_wait_timeout` to a few seconds (session, parameter group or proxy initialization query) instead of 50 s and one year?
- [ ] Does the error handler `ROLLBACK` the transaction on 1205 before retrying or reporting, never `COMMIT`?
- [ ] Does every write transaction run in a bounded retry loop that re-runs the whole transaction function on 1213, keyed on the error number?
- [ ] Do transactions that lock several rows or tables lock them in the same order (`ORDER BY` the key)?
- [ ] Is anything alerting on long-running transactions (`information_schema.innodb_trx.trx_started`) and on history list length (`trx_rseg_history_len`)?

## When not to apply

- Reports, exports and `mysqldump --single-transaction` need one snapshot across many statements: keep REPEATABLE READ with `START TRANSACTION READ ONLY` (or `WITH CONSISTENT SNAPSHOT`), use no locking reads, and run them on a replica, since they still hold back purge while open.
- Code that relies on the gap lock to stop a concurrent insert (for example, check-then-insert of a row that must not exist yet) needs REPEATABLE READ or a unique constraint; READ COMMITTED would let the phantom in. Prefer the unique constraint.
- Statement-based binary logging (`binlog_format = STATEMENT`) rules out READ COMMITTED and makes `SKIP LOCKED` and `NOWAIT` unsafe; move to row-based logging first.
- Batch jobs and migrations run as a different user or session, where a few-second `innodb_lock_wait_timeout` would abort legitimate long waits; give them their own longer values, but keep a short `lock_wait_timeout` on DDL so a blocked `ALTER TABLE` gives up instead of waiting up to a year for the metadata lock.
- `SKIP LOCKED` is wrong when the reader must see every matching row, such as totals or uniqueness checks; it hides rows by design.
