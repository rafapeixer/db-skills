---
description: "Paginated list in MySQL"
tags: [mysql, core]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
MySQL 8.4. Table `orders (id BIGINT PRIMARY KEY AUTO_INCREMENT, customer_id BIGINT, created_at DATETIME(6), total DECIMAL(12,2))` with an index on `(customer_id, created_at, id)`. Write `query.sql` with the query our infinite-scroll API runs to fetch the next 20 orders of one customer, newest first; customers can have tens of thousands of orders. Write the file; no explanation needed.
