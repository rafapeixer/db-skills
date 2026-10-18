-- The same claim with SKIP LOCKED: workers never wait on each other's rows.
-- Work (1 ms) happens after the commit, outside the transaction.
-- MySQL has no UPDATE ... RETURNING, so the claim is a locking SELECT and an
-- UPDATE in one transaction: 4 round trips (PostgreSQL needs 1).
local ffi = require("ffi")
ffi.cdef("int usleep(unsigned int usec);")

function thread_init()
  con = sysbench.sql.driver():connect()
  -- Both queue variants run under READ COMMITTED. Under the default
  -- REPEATABLE READ, the UPDATE that moves a row from 'pending' to 'done' in
  -- the (status, id) index needs an insert-intention lock on a gap that other
  -- claimers hold with next-key locks, and workers deadlock (error 1213).
  con:query("SET SESSION transaction_isolation = 'READ-COMMITTED'")
  claim = con:prepare("SELECT id INTO @id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED")
  done = con:prepare("UPDATE jobs SET status = 'done', claimed_at = NOW(6) WHERE id = @id")
end

function event()
  con:query("BEGIN")
  claim:execute()
  done:execute()
  con:query("COMMIT")
  ffi.C.usleep(1000)
end

function thread_done()
  claim:close(); done:close()
  con:disconnect()
end
