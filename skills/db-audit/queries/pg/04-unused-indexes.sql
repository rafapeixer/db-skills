-- Indexes never scanned since the stats window began, excluding primary keys,
-- unique indexes and indexes that back a constraint (dropping those changes
-- behavior, not just speed).
-- Counters are per instance: an index unused on the primary may serve reads
-- on a replica. Run this on every instance before proposing a drop, and do
-- not propose one when the window is shorter than a full business cycle.
-- last_idx_scan (PG 16+) is read through to_jsonb so the file runs on 15.
SELECT s.schemaname,
       s.relname AS table_name,
       s.indexrelname AS index_name,
       s.idx_scan,
       (to_jsonb(s) ->> 'last_idx_scan')::timestamptz AS last_idx_scan,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
       pg_relation_size(s.indexrelid) AS index_bytes,
       pg_get_indexdef(s.indexrelid) AS definition
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisunique
  AND NOT i.indisprimary
  AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = s.indexrelid)
ORDER BY pg_relation_size(s.indexrelid) DESC
LIMIT 50;

-- Stats window for the counters above.
SELECT pg_postmaster_start_time() AS server_started,
       stats_reset AS database_stats_reset,
       pg_is_in_recovery() AS on_replica
FROM pg_stat_database
WHERE datname = current_database();
