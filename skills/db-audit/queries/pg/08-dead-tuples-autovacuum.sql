-- Dead tuples and autovacuum lag. vacuum_trigger is the global trigger point
-- (threshold + scale factor x reltuples); per-table storage parameters
-- override it and are shown in table_options. A table above its trigger with
-- an old last_autovacuum means autovacuum is not keeping up or is held back.
SELECT t.schemaname,
       t.relname AS table_name,
       t.n_live_tup,
       t.n_dead_tup,
       round(100.0 * t.n_dead_tup / nullif(t.n_live_tup + t.n_dead_tup, 0), 1) AS dead_pct,
       round(current_setting('autovacuum_vacuum_threshold')::numeric
             + current_setting('autovacuum_vacuum_scale_factor')::numeric * greatest(c.reltuples, 0)::numeric) AS vacuum_trigger,
       t.last_vacuum,
       t.last_autovacuum,
       t.autovacuum_count,
       t.last_autoanalyze,
       t.n_mod_since_analyze,
       round(100.0 * t.n_tup_hot_upd / nullif(t.n_tup_upd, 0), 1) AS hot_update_pct,
       c.reloptions AS table_options,
       pg_size_pretty(pg_total_relation_size(t.relid)) AS total_size
FROM pg_stat_user_tables t
JOIN pg_class c ON c.oid = t.relid
ORDER BY t.n_dead_tup DESC
LIMIT 20;

-- Transaction ID age per database against the forced anti-wraparound vacuum.
SELECT datname,
       age(datfrozenxid) AS xid_age,
       round(100.0 * age(datfrozenxid) / current_setting('autovacuum_freeze_max_age')::numeric, 1) AS pct_of_freeze_max_age
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- Oldest tables in this database by relfrozenxid.
SELECT c.oid::regclass AS table_name,
       age(c.relfrozenxid) AS xid_age,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c
WHERE c.relkind IN ('r', 'm', 't')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 10;

-- Vacuums running now.
SELECT p.pid,
       p.relid::regclass AS table_name,
       p.phase,
       p.heap_blks_total,
       p.heap_blks_scanned,
       p.heap_blks_vacuumed
FROM pg_stat_progress_vacuum p;
