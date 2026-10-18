---
type: regex
target: { source: file, path: queue.sql }
pattern: 'SKIP\s+LOCKED'
flags: i
match: contains
---
