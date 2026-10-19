---
name: pg-vacuum-and-bloat
description: Use when a PostgreSQL table or index keeps growing, designing update- or delete-heavy tables, writing mass DELETE or UPDATE jobs, or someone proposes VACUUM FULL. Key rules: never disable autovacuum, tune it per hot table; an open or idle-in-transaction session stops vacuum from removing any dead row, so set idle_in_transaction_session_timeout; fillfactor below 100 and no index on hot-updated columns for HOT updates; delete in batches; never VACUUM FULL a live table.
metadata:
  verified: 2026-10-19
---

# Vacuum and bloat

## The decision

Every `UPDATE` and `DELETE` in PostgreSQL leaves the old row version behind as a dead tuple. Only `VACUUM` makes that space reusable, and it can only remove tuples that no open transaction might still see. The decision is how you keep that cleanup ahead of the write rate: leave autovacuum on and tune it per hot table, keep transactions short so vacuum can do its job, design hot tables so updates are HOT, and never fix bloat with a lock that takes the table offline. Getting it wrong costs disk, cache and I/O on every scan of a table that is mostly dead space, index bloat from non-HOT updates, outages from `VACUUM FULL`, and in the worst case a database that refuses new transactions to avoid XID wraparound.

## The rule

1. Never disable autovacuum, globally or with `autovacuum_enabled = false` on a table; tune it instead.
2. On large or hot tables, set per-table `autovacuum_vacuum_scale_factor` and `autovacuum_vacuum_threshold` with `ALTER TABLE ... SET (...)`, and on PG 18+ lower `autovacuum_vacuum_max_threshold` where the 100,000,000 default is too lazy.
3. Keep transactions short and set `idle_in_transaction_session_timeout` (and `transaction_timeout`, PG 17+), because any open transaction holds back the xmin horizon and VACUUM cannot remove tuples that died after it started.
4. Design update-heavy tables for HOT updates: `fillfactor` below 100 and no index on the columns you update on every request, then check `n_tup_hot_upd` against `n_tup_upd`.
5. Run large `DELETE` and `UPDATE` jobs in bounded batches with a commit per batch, and purge time-based data by dropping or detaching partitions instead of a mass `DELETE`.
6. Never run `VACUUM FULL`, `CLUSTER` or a plain `REINDEX` on a live table; the first two take `ACCESS EXCLUSIVE` for the whole rewrite and need disk for a full second copy, `REINDEX` blocks writes until the rebuild ends, and `REINDEX CONCURRENTLY` is the online form.
7. Measure bloat with `pgstattuple` (exact) or `pgstattuple_approx` (cheaper), not with estimation formulas.
8. Monitor `age(datfrozenxid)` and `age(relfrozenxid)` against `autovacuum_freeze_max_age` (default 200 million) and alert long before the server's own wraparound warnings.

## Why

**Autovacuum off does not stop the work, it delays it.** The docs say "It is unwise to disable the daemon completely unless you have an extremely predictable workload", and anti-wraparound vacuums run "even if autovacuum is nominally disabled", so turning it off only means the vacuum that eventually runs is a forced, larger one. A table with `autovacuum_enabled = false` "will not be autovacuumed, except to prevent transaction ID wraparound" ([routine vacuuming](https://www.postgresql.org/docs/18/routine-vacuuming.html), [storage parameters](https://www.postgresql.org/docs/18/sql-createtable.html#SQL-CREATETABLE-STORAGE-PARAMETERS)). AWS says the same for RDS: "We strongly recommend that you use the autovacuum feature" ([RDS autovacuum](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Autovacuum.html)).

**The default trigger scales with table size.** Autovacuum vacuums a table when dead tuples exceed `Minimum(vacuum max threshold, vacuum base threshold + vacuum scale factor * number of tuples)`. The defaults are 50 + 20% of `reltuples`, and on PG 18 a cap of 100,000,000 ([routine vacuuming](https://www.postgresql.org/docs/18/routine-vacuuming.html#AUTOVACUUM), [vacuum settings](https://www.postgresql.org/docs/18/runtime-config-vacuum.html)). For a 50-million-row table that is 10 million dead rows before the first vacuum. All three settings can be overridden per table, and the good example shows them landing in `pg_class.reloptions`. Before PG 18 there is no cap, so the per-table scale factor is the only lever. The values in the example (0.01 and 1000) are a starting point to adjust while you watch `n_dead_tup`, not a number from the docs.

**An open transaction makes dead tuples unremovable.** "An open transaction prevents vacuuming away recently-dead tuples that may be visible only to this transaction; so remaining idle for a long time can contribute to table bloat" ([idle_in_transaction_session_timeout](https://www.postgresql.org/docs/18/runtime-config-client.html#GUC-IDLE-IN-TRANSACTION-SESSION-TIMEOUT)). The horizon is set by the oldest `backend_xid` or `backend_xmin` in `pg_stat_activity`, plus replication slots and prepared transactions. The bad example opens one idle transaction in a second session; `VACUUM (VERBOSE)` then reports `0 removed ... 2000 are dead but not yet removable` on both PG 15 and 18, and `pgstattuple` still counts 2000 dead tuples. After `ROLLBACK`, the same `VACUUM` removes all 2000. Both timeouts default to 0 (disabled). `transaction_timeout` was added in PG 17 ([release 17](https://www.postgresql.org/docs/17/release-17.html)).

**HOT updates skip the indexes and clean themselves up.** An update is HOT when it "does not modify any columns referenced by the table's indexes, not including summarizing indexes" (BRIN) and "there is sufficient free space on the page containing the old row". Then no new index entries are written, and old versions in the chain can be pruned during normal operation, including `SELECT`s, without waiting for vacuum ([HOT](https://www.postgresql.org/docs/18/storage-hot.html)). `fillfactor` (default 100, range 10 to 100) reserves free space on each page for exactly this ([fillfactor](https://www.postgresql.org/docs/18/sql-createtable.html#RELOPTION-FILLFACTOR)). In the examples the same 2,000 updates are 2,000 HOT updates with `fillfactor = 90` and the hot column unindexed, and 0 HOT updates when that column has an index. An index you add "just in case" on a counter or status column costs you every HOT update on that table.

**One giant transaction is one giant pile of dead tuples.** A single `DELETE` of millions of rows creates all of its dead tuples at once, and none can be removed until it commits; meanwhile it is itself the oldest transaction holding the horizon for every other table in the database. Batches with a commit each let autovacuum reclaim space as you go and keep each transaction short. For time-based retention, "dropping an individual partition using `DROP TABLE`, or doing `ALTER TABLE DETACH PARTITION`, is far faster than a bulk operation" and "entirely avoid[s] the `VACUUM` overhead caused by a bulk `DELETE`" ([partitioning](https://www.postgresql.org/docs/18/ddl-partitioning.html)).

**Plain VACUUM is online; VACUUM FULL is not.** Plain `VACUUM` "can operate in parallel with normal reading and writing of the table, as an exclusive lock is not obtained"; the space is kept for reuse in the same table, not returned to the OS (except empty pages at the end). `VACUUM FULL` "rewrites the entire contents of the table into a new disk file", "requires an `ACCESS EXCLUSIVE` lock", needs extra disk for the new copy, and is "not recommended for routine use" ([VACUUM](https://www.postgresql.org/docs/18/sql-vacuum.html)). `ACCESS EXCLUSIVE` blocks even `SELECT`. The bad example measures it on PG 15 and 18: with a report holding `ACCESS SHARE` on `page_counters`, a `VACUUM FULL` from another session queues for `ACCESS EXCLUSIVE`, a plain `SELECT ... WHERE id = 1` that arrives after it fails with `55P03`, and the table has a new filenode when it finishes. `CLUSTER` does the same rewrite under the same lock (`pg_locks` shows `ACCESS EXCLUSIVE` plus the index rebuild's `SHARE` until commit). A plain `REINDEX` holds `SHARE` on the table, so writes wait for the whole rebuild, and `ACCESS EXCLUSIVE` on the index, so reads that use it wait too. For bloated indexes use `REINDEX CONCURRENTLY` ([REINDEX](https://www.postgresql.org/docs/18/sql-reindex.html)).

**Measure, do not estimate.** `pgstattuple` "always performs a full-table scan and returns an exact count of live and dead tuples (and their sizes) and free space", under only a read lock. `pgstattuple_approx` skips all-visible pages using the visibility map and gives exact dead-tuple counts with estimated live tuples and free space. Both need superuser or the `pg_stat_scan_tables` role ([pgstattuple](https://www.postgresql.org/docs/18/pgstattuple.html)). It is a contrib extension shipped in the official Docker image.

**Wraparound is the failure that stops writes.** XIDs are 32-bit. Autovacuum forces an aggressive vacuum on any table older than `autovacuum_freeze_max_age` (default 200 million), even with autovacuum disabled. The server warns at 40 million transactions from wraparound and "will refuse to assign new XIDs once there are fewer than three million transactions left" ([preventing XID wraparound](https://www.postgresql.org/docs/18/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND)). The same xmin holders that cause bloat (long transactions, abandoned replication slots, prepared transactions) also block freezing. On RDS, `rds.adaptive_autovacuum` (on by default) makes autovacuum more aggressive once `MaximumUsedTransactionIDs` reaches `autovacuum_freeze_max_age` or 500,000,000, whichever is greater, but AWS still says to alarm on wraparound ([RDS autovacuum](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Autovacuum.html)).

**Version notes.** PG 17 "allow[s] vacuum to more efficiently store tuple references", and vacuum "is no longer silently limited to one gigabyte of memory when `maintenance_work_mem` or `autovacuum_work_mem` are higher" ([release 17](https://www.postgresql.org/docs/17/release-17.html)). On PG 16 and older, a vacuum with more dead tuples than fits in 1 GB (about 179 million, per [AWS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Autovacuum.html)) has to scan the indexes more than once. PG 18 adds `autovacuum_vacuum_max_threshold` ([vacuum settings](https://www.postgresql.org/docs/18/runtime-config-vacuum.html)).

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
CREATE TABLE page_counters (
  id    bigint PRIMARY KEY,
  path  text   NOT NULL,
  hits  bigint NOT NULL DEFAULT 0
) WITH (fillfactor = 90);

ALTER TABLE page_counters SET (
  autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_vacuum_threshold = 1000
);

-- Update every 10th row, touching only the non-indexed column.
UPDATE page_counters SET hits = hits + 1 WHERE id % 10 = 0;

-- Statistics are flushed asynchronously; force it (PG 15+).
SELECT pg_stat_force_next_flush();

-- Plain VACUUM: no ACCESS EXCLUSIVE lock, reads and writes keep running.
VACUUM page_counters;
```

The test asserts that the storage parameters are in `pg_class.reloptions` (plus `autovacuum_vacuum_max_threshold` on PG 18), that all 2,000 updates are HOT (`n_tup_hot_upd = n_tup_upd`), that `pgstattuple` shows dead tuples before `VACUUM` and zero after, that a purge of 10,000 rows in batches of 2,000 with a commit each ends with only live rows after `VACUUM`, and that `age(datfrozenxid)` is below `autovacuum_freeze_max_age`.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
CREATE INDEX page_counters_hits_idx ON page_counters (hits);

SELECT dblink_connect('holder', 'dbname=' || current_database());
SELECT dblink_exec('holder', 'BEGIN');
SELECT * FROM dblink('holder', 'SELECT txid_current()') AS t(xid bigint);

-- MISTAKE: updating an indexed column. No update can be HOT, so every
-- one adds index entries.
UPDATE page_counters SET hits = hits + 1 WHERE id % 10 = 0;

-- MISTAKE: running VACUUM and assuming the space is reclaimed. The open
-- transaction is older than the dead tuples, so they are "dead but not
-- yet removable" and VACUUM keeps every one of them.
VACUUM page_counters;
```

```sql
SELECT dblink_send_query('maintenance', 'VACUUM FULL page_counters');
```

```sql
-- MISTAKE: CLUSTER as a "faster VACUUM FULL": the same rewrite under the
-- same lock, held until the transaction commits.
BEGIN;
SELECT pg_relation_filenode('page_counters') AS node_before \gset
CLUSTER page_counters USING page_counters_pkey;
```

The test asserts that the second session is `idle in transaction` with an XID, that 0 of the 2,000 updates are HOT, and that after `VACUUM` `pgstattuple` still counts at least 2,000 dead tuples. It then rolls the second session back and shows the same `VACUUM` removing them all, so it fails if the open transaction stops holding the horizon. It then shows the lock-based "fixes": a `VACUUM FULL` queued behind a report blocks a plain `SELECT` (`55P03`) and leaves the table with a new filenode; `CLUSTER` holds `ACCESS EXCLUSIVE` (plus `SHARE`) and rewrites the table; a plain `REINDEX` holds `SHARE` on the table and `ACCESS EXCLUSIVE` on the index.

## Checklist

When reviewing schema or SQL under this skill, confirm:

- [ ] No `autovacuum = off` and no `autovacuum_enabled = false` on any table.
- [ ] Large or update-heavy tables have per-table `autovacuum_vacuum_scale_factor` / `autovacuum_vacuum_threshold` (and on PG 18+, `autovacuum_vacuum_max_threshold` where needed), visible in `pg_class.reloptions`.
- [ ] `idle_in_transaction_session_timeout` is set for application roles, and nothing (job, migration, report, open psql) keeps a transaction open for minutes; `pg_stat_activity` shows no old `backend_xmin`.
- [ ] Update-heavy tables have `fillfactor` below 100 and no index on a column changed by every update, and `n_tup_hot_upd / n_tup_upd` is checked.
- [ ] Mass `DELETE` / `UPDATE` jobs run in batches with a commit per batch, or retention uses `DROP` / `DETACH PARTITION`.
- [ ] No `VACUUM FULL`, `CLUSTER` or plain `REINDEX` on a table that serves traffic; bloated indexes use `REINDEX CONCURRENTLY`.
- [ ] Bloat claims come from `pgstattuple` or `pgstattuple_approx`, not an estimate query.
- [ ] Alerts exist on `age(datfrozenxid)` against `autovacuum_freeze_max_age`, and on replication slots and prepared transactions that hold back the horizon.

## When not to apply

- Append-only tables that are never updated or deleted (logs, events): keep `fillfactor` at 100, which the docs call "the best choice" for them, and leave the update-oriented autovacuum tuning alone. Insert-driven vacuums still run for freezing and the visibility map.
- A table that has to shrink on disk after most of its rows were deleted and no online rewrite is available: `VACUUM FULL` is acceptable in a maintenance window where the `ACCESS EXCLUSIVE` lock and the second copy's disk are planned for.
- A one-off bulk load into a new table nobody reads yet: disabling autovacuum on it for the load is fine if you run `VACUUM (ANALYZE)` right after and turn it back on.
- Indexes on a frequently updated column that queries really need: keep the index and accept non-HOT updates, but then tune autovacuum on that table more aggressively.
