---
type: regex
target: { source: file, path: lock.sql }
pattern: 'pg_(try_)?advisory_lock\s*\('
flags: i
match: not_contains
---
