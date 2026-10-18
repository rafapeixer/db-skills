---
description: "UUID primary key on Postgres 18"
tags: [postgres, core]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
PostgreSQL 18. Write `schema.sql` creating an `events` table with a very high insert rate. Its id is exposed in our public API, so it must be a UUID. Columns: id, account_id, type, payload, created_at. Write the file; no explanation needed.
