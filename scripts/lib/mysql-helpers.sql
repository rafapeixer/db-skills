-- Assertion helpers loaded into every MySQL example database before its
-- test.sql. Check plans with EXPLAIN FORMAT=JSON INTO @plan SELECT ... (MySQL 8.1+),
-- which never executes the query, then assert on @plan.

-- Examples generate data with recursive CTEs; allow them to be deep.
SET SESSION cte_max_recursion_depth = 10000000;

DELIMITER $$

CREATE PROCEDURE assert_true(IN cond BOOLEAN, IN msg VARCHAR(255))
BEGIN
  IF cond IS NULL OR NOT cond THEN
    SET @assert_msg = LEFT(CONCAT('assertion failed: ', msg), 128);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = @assert_msg;
  END IF;
END$$

-- plan_has reports whether a JSON plan mentions the given access type
-- ('ALL' is a full scan; 'ref', 'range', 'eq_ref', 'const' use an index)
-- or the given index name.
CREATE FUNCTION plan_has(plan JSON, needle VARCHAR(255)) RETURNS BOOLEAN DETERMINISTIC
BEGIN
  RETURN JSON_SEARCH(plan, 'one', needle) IS NOT NULL;
END$$

DELIMITER ;
