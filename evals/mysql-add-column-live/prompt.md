---
description: "New column on a large live MySQL table"
tags: [mysql, core]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
Our MySQL 8.4 production database has an `orders` table with about 100 million rows and constant traffic. Add a nullable `coupon_code VARCHAR(32)` column. Write `migration.sql`; no explanation needed.
