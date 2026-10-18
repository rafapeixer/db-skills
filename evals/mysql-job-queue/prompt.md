---
description: "MySQL job queue claimed by 20 concurrent workers"
tags: [mysql, core]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
MySQL 8.4 on RDS with default settings. Write `queue.sql` with a `jobs` table (id, status, payload, created_at) and the exact statements, including any session settings, that each of our 20 concurrent workers runs to claim the next pending job, mark it done after processing it (processing takes about 1 s in the application), and commit. Write the file; no explanation needed.
