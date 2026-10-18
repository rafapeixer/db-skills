---
description: "Foreign key on a large live Postgres table"
tags: [postgres, core]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
Our PostgreSQL 17 production database has an `orders` table with about 200 million rows and constant writes, and a `customers` table. Add a foreign key from `orders.customer_id` to `customers.id`. Write `migration.sql`; no explanation needed.
