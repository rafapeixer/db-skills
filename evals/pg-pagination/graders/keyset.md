---
type: regex
target: { source: file, path: query.sql }
pattern: 'created_at\s*\)?\s*<|\(\s*created_at\s*,\s*id\s*\)\s*<'
flags: i
match: contains
---
