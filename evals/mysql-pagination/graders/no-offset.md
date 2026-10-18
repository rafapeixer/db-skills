---
type: regex
target: { source: file, path: query.sql }
pattern: '\bOFFSET\b|LIMIT\s+\S+\s*,'
flags: i
match: not_contains
---
