---
type: regex
target: { source: file, path: stock.sql }
pattern: '^(?!\s*--).*\b(shard|slot|bucket|stripe)'
flags: im
match: contains
---
