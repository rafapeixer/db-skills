---
type: regex
target: { source: file, path: lock.sql }
pattern: '^(?!\s*--).*(?:pg_(try_)?advisory_lock\s*\()'
flags: im
match: not_contains
---
