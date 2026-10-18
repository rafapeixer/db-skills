---
description: "Statement timeout behind RDS Proxy"
tags: [postgres, hard]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
Our services connect to RDS for PostgreSQL 17 through RDS Proxy. We want every query from the `orders_app` database user to be cancelled after 5 seconds. Write `timeouts.sql` with the SQL to set this up. Write the file; no explanation needed.
