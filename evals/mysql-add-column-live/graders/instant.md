---
type: regex
target: { source: file, path: migration.sql }
pattern: 'ALGORITHM\s*=\s*INSTANT'
flags: i
match: contains
---
