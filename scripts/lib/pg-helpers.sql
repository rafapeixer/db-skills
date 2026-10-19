-- Assertion helpers loaded into every PostgreSQL example database before
-- its test.sql. Plans come from EXPLAIN without ANALYZE, so checking a plan
-- never executes the query.

-- Workflow queries read pg_stat_statements; the test server preloads it.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE FUNCTION assert_true(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond IS NOT TRUE THEN
    RAISE EXCEPTION 'assertion failed: %', msg;
  END IF;
END
$$;

-- plan_json returns the planner's plan for a query as JSON.
CREATE FUNCTION plan_json(query text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  plan jsonb;
BEGIN
  EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF) ' || query INTO plan;
  RETURN plan;
END
$$;

-- plan_has reports whether any node of the plan has the given type,
-- for example 'Index Scan', 'Index Only Scan', 'Seq Scan', 'Sort'.
CREATE FUNCTION plan_has(query text, node_type text) RETURNS boolean
LANGUAGE sql AS $$
  SELECT jsonb_path_exists(plan_json(query), '$.** ? (@."Node Type" == $t)', jsonb_build_object('t', node_type));
$$;

-- held_locks lists the relation-level locks this session holds right now
-- on a table or index, so an example can show the lock mode a statement
-- keeps until commit ('AccessExclusiveLock', 'ShareLock', ...).
CREATE FUNCTION held_locks(rel regclass) RETURNS text
LANGUAGE sql AS $$
  SELECT string_agg(mode, ',' ORDER BY mode) FROM pg_locks
  WHERE locktype = 'relation' AND relation = rel AND pid = pg_backend_pid() AND granted;
$$;

-- xact_seq_scans counts sequential scans of a table in the current
-- transaction (counters are not flushed while a transaction is open, so a
-- delta inside one is exact). A statement that scans the table shows here.
CREATE FUNCTION xact_seq_scans(rel regclass) RETURNS bigint
LANGUAGE sql AS $$
  SELECT coalesce((SELECT seq_scan FROM pg_stat_xact_user_tables WHERE relid = rel), 0);
$$;

-- assert_error runs a statement that must fail with the given SQLSTATE
-- (for example '23505' unique_violation, '55P03' lock_not_available).
CREATE FUNCTION assert_error(stmt text, expected_sqlstate text, msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = expected_sqlstate THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'assertion failed: %: expected SQLSTATE %, got % (%)', msg, expected_sqlstate, SQLSTATE, SQLERRM;
  END;
  RAISE EXCEPTION 'assertion failed: %: statement succeeded, expected SQLSTATE %', msg, expected_sqlstate;
END
$$;
