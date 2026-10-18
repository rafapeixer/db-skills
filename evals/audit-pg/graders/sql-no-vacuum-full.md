---
type: regex
target: { source: file, path: migration.sql }
# Only statements count: a comment that warns against VACUUM FULL is fine.
pattern: '^(?!\s*--).*\bVACUUM\s*(\([^)]*FULL|FULL)'
flags: im
match: not_contains
---
