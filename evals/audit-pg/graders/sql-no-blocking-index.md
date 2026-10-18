---
type: regex
# A commented rollback that starts with CREATE INDEX counts on purpose: someone copies it onto the
# live database. Prose that mentions CREATE INDEX mid-line does not.
target: { source: file, path: migration.sql }
pattern: '^\s*(--\s*)?(rollback:?\s*)?CREATE\s+(UNIQUE\s+)?INDEX\s+(?!CONCURRENTLY)'
flags: im
match: not_contains
---
