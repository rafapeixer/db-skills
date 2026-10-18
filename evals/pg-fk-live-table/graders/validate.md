---
type: regex
target: { source: file, path: migration.sql }
pattern: 'VALIDATE\s+CONSTRAINT'
flags: i
match: contains
---
