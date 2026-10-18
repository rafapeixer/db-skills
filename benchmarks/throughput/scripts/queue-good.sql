-- The same claim with SKIP LOCKED in one statement: workers never wait on
-- each other's rows. Work happens after the claim, outside the transaction.
UPDATE jobs SET status = 'done', claimed_at = now()
WHERE id = (SELECT id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED);
\sleep 1 ms
