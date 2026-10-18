-- A worker claims one job: every worker locks the same first pending row and
-- waits for the others. Work happens inside the transaction.
BEGIN;
SELECT id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE \gset
\sleep 1 ms
UPDATE jobs SET status = 'done', claimed_at = now() WHERE id = :id;
COMMIT;
