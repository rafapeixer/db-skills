---
type: regex
target: { source: file, path: query.sql }
pattern: '\(\s*created_at\s*,\s*id\s*\)\s*<'
flags: i
match: not_contains
---
