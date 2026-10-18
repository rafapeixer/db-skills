---
type: regex
target: { source: file, path: schema.sql }
pattern: '^(?!\s*--).*(?:DEFAULT\s+(gen_random_uuid|uuid_generate_v4)\s*\()'
flags: im
match: not_contains
---
