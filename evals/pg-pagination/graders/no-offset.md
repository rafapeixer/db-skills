---
type: regex
target: { source: file, path: query.sql }
pattern: '^(?!\s*--).*(?:\bOFFSET\b)'
flags: im
match: not_contains
---
