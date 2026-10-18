---
type: llm
focus: { source: file, path: audit.md }
---
PASS if the report computes that the fleet can open more connections than the database allows (12 replicas x 2 workers x pool 4 = 96, more during a rolling deploy surge, against max_connections 100 minus reserved/admin slots) and proposes smaller pools and/or a pooler. FAIL otherwise.
