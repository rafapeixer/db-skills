---
type: llm
focus: { source: file, path: audit.md }
---
PASS if the report identifies the index orders_status as redundant because orders_status_created starts with the same column (status), and proposes dropping orders_status. FAIL otherwise.
