---
type: llm
focus: { source: file, path: audit.md }
---
PASS if the report identifies the session in state 'idle in transaction' (billing-worker) as a problem (held locks, blocked vacuum) and proposes ending it and/or setting idle_in_transaction_session_timeout. FAIL otherwise.
