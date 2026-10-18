---
description: "Pool size for a multi-worker fleet"
tags: [postgres, hard]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
Our Python FastAPI service runs 12 replicas, each with 2 uvicorn workers, and each worker has its own asyncpg pool. Rolling deploys add 3 extra replicas while they run. PostgreSQL has max_connections = 100 and we keep 10 connections for admin and migrations. Write `pool.md` with one line in the form `max_size = N` giving the largest safe asyncpg pool max_size per worker, followed by the arithmetic. Write the file; no further explanation needed.
