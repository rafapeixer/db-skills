db-skills is installed. Before writing or reviewing SQL, a migration, a pool setting or a job for PostgreSQL or MySQL, load the matching db-skills skill (pg-* or mysql-*), even for a one-line query. Traps these skills exist to catch:
- MySQL keyset pagination: write it out as `created_at < ? OR (created_at = ? AND id < ?)`; MySQL does not range-scan `(created_at, id) < (?, ?)`. Never OFFSET or LIMIT offset, in either engine.
- Behind PgBouncer transaction pooling or RDS Proxy: `pg_advisory_xact_lock` inside a transaction, never session-level `pg_advisory_lock` / `pg_try_advisory_lock`.
- Deadlock or serialization failure (MySQL 1213, PostgreSQL 40001/40P01): retry the whole transaction, never only the failed statement.
- Live tables: PostgreSQL `CREATE INDEX CONCURRENTLY`, `NOT VALID` then `VALIDATE`, `lock_timeout` on every DDL; MySQL explicit `ALGORITHM` and `LOCK` plus a short `lock_wait_timeout`.
- Queues claim with `FOR UPDATE SKIP LOCKED`; in MySQL the claiming session uses READ COMMITTED.
- Hot counters: shard the row; one row serializes every writer.
