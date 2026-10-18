---
type: regex
target: { source: file, path: migration.sql }
pattern: 'CREATE\s+(UNIQUE\s+)?INDEX\s+CONCURRENTLY'
flags: i
match: contains
---
