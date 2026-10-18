---
type: regex
target: { source: file, path: query.sql }
pattern: '^(?!\s*--).*(?:\(\s*created_at\s*,\s*id\s*\)\s*<)'
flags: im
match: not_contains
---
