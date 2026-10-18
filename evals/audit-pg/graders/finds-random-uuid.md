---
type: llm
focus: { source: file, path: audit.md }
---
PASS if the report flags the events table's random UUID primary key (gen_random_uuid()) on a high-insert table as costly for the index and proposes a time-ordered key (UUIDv7, uuidv7() on PostgreSQL 18, or bigint identity). FAIL otherwise.
