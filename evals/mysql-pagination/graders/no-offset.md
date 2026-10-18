---
type: regex
target: { source: file, path: query.sql }
pattern: '^(?!\s*--).*(?:\bOFFSET\b|LIMIT\s+\S+\s*,)'
flags: im
match: not_contains
---
