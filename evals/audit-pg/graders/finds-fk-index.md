---
type: llm
focus: { source: file, path: audit.md }
---
PASS if the report identifies that orders.customer_id has a foreign key but no index, so deleting or updating customers scans the orders table, and proposes an index on orders.customer_id. FAIL otherwise.
