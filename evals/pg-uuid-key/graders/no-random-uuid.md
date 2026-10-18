---
type: regex
target: { source: file, path: schema.sql }
pattern: 'DEFAULT\s+(gen_random_uuid|uuid_generate_v4)\s*\('
flags: i
match: not_contains
---
