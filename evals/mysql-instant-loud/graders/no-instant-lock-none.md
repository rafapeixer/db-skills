---
type: regex
target: { source: file, path: migration.sql }
pattern: '^(?!\s*--).*(?:ALGORITHM\s*=\s*INSTANT\s*,\s*LOCK\s*=\s*NONE|LOCK\s*=\s*NONE\s*,\s*ALGORITHM\s*=\s*INSTANT)'
flags: im
match: not_contains
---
