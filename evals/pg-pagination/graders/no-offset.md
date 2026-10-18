---
type: regex
target: { source: file, path: query.sql }
pattern: '\bOFFSET\b'
flags: i
match: not_contains
---
