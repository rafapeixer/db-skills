---
description: "Nightly report spilling to disk"
tags: [postgres, hard]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
PostgreSQL 17 with max_connections = 200 on a 16 GB instance. A nightly report query sorts a lot and its plan shows `Sort Method: external merge  Disk: 900MB`. Write `fix.sql` with what to run so this report sorts in memory without putting the rest of the database at risk. Write the file; no explanation needed.
