-- Good: an update-heavy table designed for HOT updates, tuned per table
-- for autovacuum, cleaned by plain VACUUM, and purged in batches.
-- pgstattuple (contrib, shipped in the official image) gives exact
-- dead-tuple counts instead of an estimate.
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- fillfactor 90 leaves 10% of every page free for new row versions.
-- hits is updated constantly and is not indexed.
CREATE TABLE page_counters (
  id    bigint PRIMARY KEY,
  path  text   NOT NULL,
  hits  bigint NOT NULL DEFAULT 0
) WITH (fillfactor = 90);

CREATE INDEX page_counters_path_idx ON page_counters (path);

INSERT INTO page_counters (id, path)
SELECT g, '/page/' || g
FROM generate_series(1, 20000) AS g;

-- Per-table autovacuum: vacuum after 1% of rows (plus 1000) change,
-- instead of the global 20% (plus 50).
ALTER TABLE page_counters SET (
  autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_vacuum_threshold = 1000
);

-- PG 18+: cap the trigger for very large tables (default 100,000,000).
DO $$
BEGIN
  IF current_setting('server_version_num')::int >= 180000 THEN
    ALTER TABLE page_counters SET (autovacuum_vacuum_max_threshold = 500000);
  END IF;
END
$$;

SELECT assert_true(
  (SELECT reloptions @> ARRAY['fillfactor=90',
                              'autovacuum_vacuum_scale_factor=0.01',
                              'autovacuum_vacuum_threshold=1000']
   FROM pg_class WHERE oid = 'page_counters'::regclass),
  'per-table storage parameters are stored in pg_class.reloptions');

SELECT assert_true(
  current_setting('server_version_num')::int < 180000
  OR (SELECT 'autovacuum_vacuum_max_threshold=500000' = ANY (reloptions)
      FROM pg_class WHERE oid = 'page_counters'::regclass),
  'PG 18+: autovacuum_vacuum_max_threshold is set per table');

-- Update every 10th row, touching only the non-indexed column.
UPDATE page_counters SET hits = hits + 1 WHERE id % 10 = 0;

-- Statistics are flushed asynchronously; force it (PG 15+).
SELECT pg_stat_force_next_flush();

SELECT assert_true(
  (SELECT n_tup_hot_upd = n_tup_upd AND n_tup_upd = 2000
   FROM pg_stat_user_tables WHERE relid = 'page_counters'::regclass),
  'every update is HOT: no indexed column changed and the page had room');

SELECT assert_true(
  (SELECT dead_tuple_count > 0 FROM pgstattuple('page_counters')),
  'the old row versions are dead tuples until VACUUM');

-- Plain VACUUM: no ACCESS EXCLUSIVE lock, reads and writes keep running.
VACUUM page_counters;

SELECT assert_true(
  (SELECT dead_tuple_count = 0 FROM pgstattuple('page_counters')),
  'VACUUM removed every dead tuple: no open transaction holds the xmin horizon');

-- Purge in bounded batches, one commit per batch, so each batch's dead
-- tuples become removable as soon as it commits.
DO $$
DECLARE
  deleted bigint;
BEGIN
  LOOP
    DELETE FROM page_counters
    WHERE id IN (SELECT id FROM page_counters WHERE id > 10000 LIMIT 2000);
    GET DIAGNOSTICS deleted = ROW_COUNT;
    EXIT WHEN deleted = 0;
    COMMIT;
  END LOOP;
END
$$;

VACUUM page_counters;

SELECT assert_true(
  (SELECT tuple_count = 10000 AND dead_tuple_count = 0
   FROM pgstattuple('page_counters')),
  'after the batched purge and VACUUM, only live rows remain');

-- Wraparound: the age of the oldest unfrozen XID per database, compared
-- with autovacuum_freeze_max_age (default 200 million).
SELECT assert_true(
  (SELECT age(datfrozenxid) < current_setting('autovacuum_freeze_max_age')::bigint
   FROM pg_database WHERE datname = current_database()),
  'database XID age is below autovacuum_freeze_max_age');
