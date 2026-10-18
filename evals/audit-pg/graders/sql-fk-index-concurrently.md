---
type: regex
target: { source: file, path: migration.sql }
pattern: 'CREATE\s+INDEX\s+CONCURRENTLY[^;]*\(\s*customer_id'
flags: i
match: contains
---
