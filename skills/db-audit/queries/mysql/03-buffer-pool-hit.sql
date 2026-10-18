-- InnoDB buffer pool hit ratio since server start: read requests that did not
-- have to read a page from disk. Meaningless shortly after a restart.
SELECT ROUND(100 * (1 - r.pages_read / NULLIF(q.read_requests, 0)), 3) AS buffer_pool_hit_pct,
       r.pages_read AS pages_read_from_disk,
       q.read_requests AS read_requests,
       ROUND(@@innodb_buffer_pool_size / 1024 / 1024) AS buffer_pool_mb
FROM (SELECT CAST(VARIABLE_VALUE AS UNSIGNED) AS pages_read
        FROM performance_schema.global_status
       WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') r
CROSS JOIN
     (SELECT CAST(VARIABLE_VALUE AS UNSIGNED) AS read_requests
        FROM performance_schema.global_status
       WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests') q;

-- Pool occupancy and implicit temporary tables that went to disk.
SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN ('Innodb_buffer_pool_pages_total', 'Innodb_buffer_pool_pages_free',
                        'Innodb_buffer_pool_pages_dirty', 'Innodb_buffer_pool_wait_free',
                        'Created_tmp_tables', 'Created_tmp_disk_tables',
                        'Sort_merge_passes', 'Uptime');
