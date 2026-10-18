---
type: llm
focus: { source: file, path: audit.md }
---
PASS if the report identifies the index orders_total as unused (zero scans) and proposes dropping it (possibly after confirming usage on replicas or over a longer window). FAIL otherwise.
