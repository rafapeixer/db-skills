-- Tables read mostly by sequential scans, ordered by rows read that way.
-- Small tables are cheap to scan; judge avg_rows_per_seq_scan and table size
-- together. last_seq_scan (PG 16+) is read through to_jsonb so the file
-- runs on 15.
SELECT t.schemaname,
       t.relname AS table_name,
       t.seq_scan,
       t.seq_tup_read,
       t.seq_tup_read / nullif(t.seq_scan, 0) AS avg_rows_per_seq_scan,
       t.idx_scan,
       round(100.0 * t.seq_scan / nullif(t.seq_scan + coalesce(t.idx_scan, 0), 0), 1) AS seq_scan_pct,
       (to_jsonb(t) ->> 'last_seq_scan')::timestamptz AS last_seq_scan,
       t.n_live_tup,
       pg_size_pretty(pg_total_relation_size(t.relid)) AS total_size
FROM pg_stat_user_tables t
WHERE t.seq_scan > 0
ORDER BY t.seq_tup_read DESC
LIMIT 20;
