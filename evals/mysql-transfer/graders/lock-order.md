---
type: regex
target: { source: file, path: transfer.sql }
pattern: 'LEAST\s*\(|GREATEST\s*\(|ORDER\s+BY\s+id'
flags: i
match: contains
---
