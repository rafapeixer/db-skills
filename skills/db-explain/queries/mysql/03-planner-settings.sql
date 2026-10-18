-- Settings that change the optimizer's choices or the cost of sorts, joins
-- and temporary tables. Names absent from this version return no row.
SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.session_variables
WHERE VARIABLE_NAME IN ('version', 'optimizer_switch', 'optimizer_search_depth',
                        'eq_range_index_dive_limit', 'range_optimizer_max_mem_size',
                        'sort_buffer_size', 'join_buffer_size', 'read_rnd_buffer_size',
                        'tmp_table_size', 'max_heap_table_size', 'temptable_max_ram',
                        'internal_tmp_mem_storage_engine', 'explain_format',
                        'max_execution_time', 'transaction_isolation',
                        'information_schema_stats_expiry')
ORDER BY VARIABLE_NAME;
