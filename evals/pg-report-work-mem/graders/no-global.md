---
type: regex
target: { source: file, path: fix.sql }
pattern: '^(?!\s*--).*(?:ALTER\s+SYSTEM\s+SET\s+work_mem)'
flags: im
match: not_contains
---
