---
type: regex
target: { source: file, path: timeouts.sql }
pattern: 'ALTER\s+(ROLE|USER)\s+\S+\s+SET\s+statement_timeout'
flags: i
match: contains
---
