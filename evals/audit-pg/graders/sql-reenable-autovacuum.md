---
type: regex
target: { source: file, path: migration.sql }
pattern: 'autovacuum_enabled\s*=\s*?(true|on)|RESET\s*\(\s*autovacuum_enabled'
flags: i
match: contains
---
