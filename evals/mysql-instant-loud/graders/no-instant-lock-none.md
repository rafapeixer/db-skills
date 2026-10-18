---
type: regex
target: { source: file, path: migration.sql }
pattern: 'ALGORITHM\s*=\s*INSTANT\s*,\s*LOCK\s*=\s*NONE|LOCK\s*=\s*NONE\s*,\s*ALGORITHM\s*=\s*INSTANT'
flags: i
match: not_contains
---
