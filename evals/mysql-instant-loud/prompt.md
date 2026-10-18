---
description: "Add column without a silent copy, MySQL"
tags: [mysql, hard]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
Our MySQL 8.4 production `orders` table has 100 million rows. Add a nullable `coupon_code VARCHAR(32)` column. The statement must fail rather than silently copy or lock the table. Write `migration.sql`; no explanation needed.
