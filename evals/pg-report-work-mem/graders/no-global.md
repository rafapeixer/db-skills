---
type: regex
target: { source: file, path: fix.sql }
pattern: 'ALTER\s+SYSTEM\s+SET\s+work_mem'
flags: i
match: not_contains
---
