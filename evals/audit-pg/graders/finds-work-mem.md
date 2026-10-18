---
type: llm
focus: { source: file, path: audit.md }
---
PASS if the report flags work_mem = 256MB as dangerous because it can be used per sort/hash operation per connection (100 connections) on a 4 GiB instance, and proposes a much smaller global value with per-query increases. FAIL otherwise.
