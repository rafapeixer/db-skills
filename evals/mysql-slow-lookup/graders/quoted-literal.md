---
type: regex
target: { source: file, path: fix.sql }
pattern: 'ref_code\s*=\s*(?:''4242''|"4242"|CAST\s*\(\s*4242\s+AS\s+CHAR)'
flags: i
match: contains
---
