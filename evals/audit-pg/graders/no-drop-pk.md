---
type: llm
focus: { source: file, path: audit.md }
---
FAIL if the report recommends dropping events_pkey, customers_pkey, order_items_pkey, orders_pkey or customers_email_key (primary key or unique constraint indexes), even though some show zero scans. PASS otherwise.
