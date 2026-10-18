---
type: llm
focus: { source: file, path: audit.md }
---
PASS if the report identifies the order_items query run once per order (thousands of calls, an N+1 pattern) and proposes loading items for many orders in one query (join, = ANY, LATERAL or similar). FAIL otherwise.
