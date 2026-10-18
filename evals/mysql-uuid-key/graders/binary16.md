---
type: regex
target: { source: file, path: schema.sql }
pattern: 'BINARY\s*\(\s*16\s*\)'
flags: i
match: contains
---
