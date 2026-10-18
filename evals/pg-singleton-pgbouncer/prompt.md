---
description: "Singleton job behind PgBouncer transaction pooling"
tags: [postgres, hard]
runs: 3
max_turns: 15
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
Our app reaches PostgreSQL 17 through PgBouncer in transaction pooling mode. A nightly billing job runs on 4 replicas but must only run once at a time. Write `lock.sql` with the SQL the job runs to make sure only one instance does the work. Write the file; no explanation needed.
