---
description: "Flash-sale stock counter under thousands of concurrent decrements"
tags: [postgres, hard]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
PostgreSQL 17. In a flash sale, one product gets about 5,000 purchase requests per second from 64 application connections. Each purchase must decrement the remaining stock by 1 and must fail when the stock runs out; the remaining stock must never go below zero or be oversold. Write `stock.sql` with the schema and the statement each purchase runs. Optimize for throughput without lock waits. Write the file; no explanation needed.
