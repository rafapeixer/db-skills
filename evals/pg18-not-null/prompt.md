---
description: "NOT NULL on a live table, PostgreSQL 18"
tags: [postgres, hard]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
Our production database is PostgreSQL 18. The `orders` table has about 200 million rows and constant writes, and every row now has a `status`. Make `orders.status` NOT NULL with the least locking that PostgreSQL 18 allows. Write `migration.sql`; no explanation needed.
