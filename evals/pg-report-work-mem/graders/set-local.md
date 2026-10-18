---
type: regex
target: { source: file, path: fix.sql }
pattern: 'SET\s+LOCAL\s+work_mem'
flags: i
match: contains
---
