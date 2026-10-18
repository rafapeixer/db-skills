-- Settings that change the plan. Compare with the values in the plan's
-- "Settings" entry (EXPLAIN SETTINGS lists the ones that differ from the
-- built-in default). Names absent from this version return no row.
SELECT name, setting, unit, source
FROM pg_settings
WHERE name IN ('server_version_num', 'work_mem', 'hash_mem_multiplier', 'effective_cache_size',
               'random_page_cost', 'seq_page_cost', 'effective_io_concurrency',
               'default_statistics_target', 'plan_cache_mode', 'jit', 'jit_above_cost',
               'max_parallel_workers_per_gather', 'enable_seqscan', 'enable_indexscan',
               'enable_bitmapscan', 'enable_hashjoin', 'enable_mergejoin', 'enable_nestloop',
               'enable_sort', 'enable_partition_pruning', 'from_collapse_limit',
               'join_collapse_limit', 'statement_timeout')
ORDER BY name;

-- Extensions that matter here: hypopg allows hypothetical indexes, but
-- installing it is DDL and the user's decision.
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('hypopg', 'pg_stat_statements', 'pg_hint_plan');
