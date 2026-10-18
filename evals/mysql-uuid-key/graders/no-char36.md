---
type: regex
target: { source: file, path: schema.sql }
pattern: '\bid\s+(CHAR|VARCHAR)\s*\(\s*36\s*\)'
flags: i
match: not_contains
---
