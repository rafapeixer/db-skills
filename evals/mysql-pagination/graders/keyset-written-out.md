---
type: regex
target: { source: file, path: query.sql }
pattern: 'created_at\s*<'
flags: i
match: contains
---
