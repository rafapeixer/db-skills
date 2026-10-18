---
type: regex
target: { source: file, path: schema.sql }
pattern: '^(?!\s*--).*(?:\bid\s+(CHAR|VARCHAR)\s*\(\s*36\s*\))'
flags: im
match: not_contains
---
