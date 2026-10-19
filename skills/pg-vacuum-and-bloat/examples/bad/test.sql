-- Bad: an index on the hot column kills HOT updates, and a forgotten
-- open transaction in another session stops VACUUM from removing dead
-- tuples. dblink opens that second session inside the test.
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS dblink;

-- MISTAKE: fillfactor left at 100 and an index on hits, the column every
-- request updates. Each update writes a new entry in every index on the
-- table, and the dead index entries bloat the indexes too.
CREATE TABLE page_counters (
  id    bigint PRIMARY KEY,
  path  text   NOT NULL,
  hits  bigint NOT NULL DEFAULT 0
);

CREATE INDEX page_counters_hits_idx ON page_counters (hits);

INSERT INTO page_counters (id, path)
SELECT g, '/page/' || g
FROM generate_series(1, 20000) AS g;

-- A second session starts a transaction, takes an XID and goes idle
-- without committing: an application that forgot COMMIT, or a pool
-- connection left "idle in transaction".
SELECT dblink_connect('holder', 'dbname=' || current_database());
SELECT dblink_exec('holder', 'BEGIN');
SELECT * FROM dblink('holder', 'SELECT txid_current()') AS t(xid bigint);

SELECT assert_true(
  (SELECT count(*) = 1 FROM pg_stat_activity
   WHERE datname = current_database() AND state = 'idle in transaction'),
  'the second session is idle in transaction');

-- MISTAKE: updating an indexed column. No update can be HOT, so every
-- one adds index entries.
UPDATE page_counters SET hits = hits + 1 WHERE id % 10 = 0;

SELECT pg_stat_force_next_flush();

SELECT assert_true(
  (SELECT n_tup_hot_upd = 0 AND n_tup_upd = 2000
   FROM pg_stat_user_tables WHERE relid = 'page_counters'::regclass),
  'no update is HOT when an indexed column changes');

-- MISTAKE: running VACUUM and assuming the space is reclaimed. The open
-- transaction is older than the dead tuples, so they are "dead but not
-- yet removable" and VACUUM keeps every one of them.
VACUUM page_counters;

SELECT assert_true(
  (SELECT dead_tuple_count >= 2000 FROM pgstattuple('page_counters')),
  'VACUUM could not remove dead tuples while the old transaction is open');

-- The xmin horizon holder is visible in pg_stat_activity.
SELECT assert_true(
  (SELECT count(*) = 1 FROM pg_stat_activity
   WHERE datname = current_database()
     AND state = 'idle in transaction'
     AND backend_xid IS NOT NULL),
  'the idle-in-transaction session holds an XID');

-- Ending the transaction releases the horizon; the same VACUUM now works.
SELECT dblink_exec('holder', 'ROLLBACK');
SELECT dblink_disconnect('holder');

VACUUM page_counters;

SELECT assert_true(
  (SELECT dead_tuple_count = 0 FROM pgstattuple('page_counters')),
  'once the transaction ends, VACUUM removes the dead tuples');

-- MISTAKE: VACUUM FULL to "get the space back". It rewrites the whole table
-- into a new file under ACCESS EXCLUSIVE, so it waits behind every running
-- query, every query that arrives after it waits behind it, and the copy
-- needs the table's size again in free disk.
SELECT pg_relation_filenode('page_counters') AS node_before \gset
SELECT dblink_connect('report', 'dbname=' || current_database());
SELECT dblink_exec('report', 'BEGIN');
SELECT * FROM dblink('report', 'SELECT count(*) FROM page_counters') AS t(n bigint);
SELECT dblink_connect('maintenance', 'dbname=' || current_database());
SELECT dblink_send_query('maintenance', 'VACUUM FULL page_counters');
DO $$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN EXISTS (SELECT 1 FROM pg_locks
      WHERE relation = 'page_counters'::regclass AND mode = 'AccessExclusiveLock' AND NOT granted);
    PERFORM pg_sleep(0.05);
  END LOOP;
END
$$;
-- A plain read from the application now waits too (bounded here at 500ms
-- only so the test can observe it).
SET lock_timeout = '500ms';
SELECT assert_error('SELECT count(*) FROM page_counters WHERE id = 1',
  '55P03', 'a plain SELECT is blocked behind the waiting VACUUM FULL');
RESET lock_timeout;
SELECT dblink_exec('report', 'COMMIT');
SELECT * FROM dblink_get_result('maintenance') AS r(status text);
SELECT dblink_disconnect('report');
SELECT dblink_disconnect('maintenance');
SELECT assert_true(pg_relation_filenode('page_counters') <> :node_before,
  'VACUUM FULL wrote a new copy of the table');

-- MISTAKE: CLUSTER as a "faster VACUUM FULL": the same rewrite under the
-- same lock, held until the transaction commits.
BEGIN;
SELECT pg_relation_filenode('page_counters') AS node_before \gset
CLUSTER page_counters USING page_counters_pkey;
SELECT assert_true(held_locks('page_counters') = 'AccessExclusiveLock,ShareLock',
  'CLUSTER holds ACCESS EXCLUSIVE on the table (plus SHARE for the index rebuild): reads and writes wait');
SELECT assert_true(pg_relation_filenode('page_counters') <> :node_before,
  'CLUSTER rewrote the table');
COMMIT;

-- MISTAKE: REINDEX without CONCURRENTLY to shrink a bloated index: SHARE on
-- the table blocks every write for the whole rebuild, and ACCESS EXCLUSIVE
-- on the index blocks the reads that use it.
BEGIN;
REINDEX INDEX page_counters_hits_idx;
SELECT assert_true(held_locks('page_counters') = 'ShareLock',
  'REINDEX holds SHARE on the table: writes wait');
SELECT assert_true(held_locks('page_counters_hits_idx') = 'AccessExclusiveLock',
  'and ACCESS EXCLUSIVE on the index');
COMMIT;
