---
description: "Paginated list in Postgres"
tags: [postgres, core]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
PostgreSQL 17. Table `orders (id bigint primary key, customer_id bigint, created_at timestamptz, total numeric)`. Write `query.sql` with the query our infinite-scroll API runs to fetch the next 20 orders of one customer, newest first; customers can have tens of thousands of orders. Write the file; no explanation needed.
