---
description: "Slow lookup on an indexed column, MySQL"
tags: [mysql, hard]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
MySQL 8.4. `orders.ref_code` is `VARCHAR(20)` with an index, but this query from our app takes seconds on 50 million rows: `SELECT id, total FROM orders WHERE ref_code = 4242;`. Write `fix.sql` with the corrected query. Write the file; no explanation needed.
