-- Share of table and index block reads served from shared_buffers since the
-- last stats reset. Meaningless right after a restart or reset: report the
-- stats window from 01-version-settings.sql next to it.
SELECT round(sum(t.heap_blks_hit) * 100.0 / nullif(sum(t.heap_blks_hit) + sum(t.heap_blks_read), 0), 2) AS table_hit_pct,
       (SELECT round(sum(i.idx_blks_hit) * 100.0 / nullif(sum(i.idx_blks_hit) + sum(i.idx_blks_read), 0), 2)
          FROM pg_statio_user_indexes i) AS index_hit_pct,
       sum(t.heap_blks_read) AS table_blocks_read_outside_shared_buffers
FROM pg_statio_user_tables t;

-- Database-wide counters, including temp files (sorts and hashes that spilled
-- to disk because they did not fit in work_mem).
SELECT datname,
       round(blks_hit * 100.0 / nullif(blks_hit + blks_read, 0), 2) AS hit_pct,
       temp_files,
       pg_size_pretty(temp_bytes) AS temp_written,
       deadlocks,
       stats_reset
FROM pg_stat_database
WHERE datname = current_database();

-- Tables doing the most reads outside shared_buffers.
SELECT schemaname,
       relname AS table_name,
       heap_blks_read,
       heap_blks_hit,
       round(heap_blks_hit * 100.0 / nullif(heap_blks_hit + heap_blks_read, 0), 1) AS hit_pct
FROM pg_statio_user_tables
WHERE heap_blks_read > 0
ORDER BY heap_blks_read DESC
LIMIT 10;
