---
type: regex
target: { source: file, path: migration.sql }
pattern: 'NOT\s+NULL\s+"?status"?\s+NOT\s+VALID'
flags: i
match: contains
---
