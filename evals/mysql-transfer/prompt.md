---
description: "Money transfer procedure on MySQL"
tags: [mysql, hard]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
MySQL 8.4. Write `transfer.sql` with a stored procedure `transfer(from_id, to_id, amount)` that moves money between two rows of `accounts(id BIGINT PRIMARY KEY, balance DECIMAL(12,2))`. Many transfers run concurrently, including between the same accounts in opposite directions. Write the file; no explanation needed.
