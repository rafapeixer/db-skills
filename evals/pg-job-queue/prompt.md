---
description: "Job queue claimed by concurrent workers"
tags: [postgres, core]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
PostgreSQL 17. Write `queue.sql` with a `jobs` table and the query that each of our 20 concurrent workers runs to claim the next batch of 10 pending jobs. Write the file; no explanation needed.
