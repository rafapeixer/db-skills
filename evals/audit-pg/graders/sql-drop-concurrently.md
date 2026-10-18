---
type: regex
target: { source: file, path: migration.sql }
pattern: 'DROP\s+INDEX\s+CONCURRENTLY'
flags: i
match: contains
---
