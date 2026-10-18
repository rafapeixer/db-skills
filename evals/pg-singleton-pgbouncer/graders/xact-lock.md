---
type: regex
target: { source: file, path: lock.sql }
pattern: 'pg_(try_)?advisory_xact_lock'
flags: i
match: contains
---
