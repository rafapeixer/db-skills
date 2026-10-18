---
type: llm
focus: { source: file, path: audit.md }
---
PASS if the report identifies the query paginating orders with OFFSET as the most expensive statement and proposes keyset (seek) pagination instead of OFFSET. FAIL otherwise.
