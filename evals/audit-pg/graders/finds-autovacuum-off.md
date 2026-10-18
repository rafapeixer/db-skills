---
type: llm
focus: { source: file, path: audit.md }
---
PASS if the report identifies that autovacuum is disabled on the orders table (autovacuum_enabled=false) while it has tens of thousands of dead tuples, and proposes re-enabling autovacuum on that table. FAIL otherwise.
