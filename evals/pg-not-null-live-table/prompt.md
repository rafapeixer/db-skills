---
description: "NOT NULL on a large live Postgres table"
tags: [postgres, core]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
Our PostgreSQL 17 production database has an `orders` table with about 200 million rows and constant writes. Every row now has a `status`; make `orders.status` NOT NULL. Write `migration.sql`; no explanation needed.
