---
type: regex
target: { source: file, path: queue.sql }
pattern: '^(?!\s*--).*READ[\s-]+COMMITTED'
flags: im
match: contains
---
