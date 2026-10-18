---
type: regex
target: { source: file, path: migration.sql }
pattern: 'NOT\s+VALID'
flags: i
match: contains
---
