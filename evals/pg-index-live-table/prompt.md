---
description: "Index on a large live Postgres table"
tags: [postgres, core]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
Our PostgreSQL 17 production database has an `orders` table with about 200 million rows and constant writes. A new query filters by `customer_id`. Write `migration.sql` with the SQL that adds the index. Write the file; no explanation needed.
