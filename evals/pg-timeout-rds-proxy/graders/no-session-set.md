---
type: regex
target: { source: file, path: timeouts.sql }
pattern: '^\s*SET\s+(SESSION\s+)?statement_timeout'
flags: im
match: not_contains
---
