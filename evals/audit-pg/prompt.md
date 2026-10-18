---
max_turns: 30
allowed_tools: [Read, Glob, Grep, Skill, Write]
---
Our DBA exported statistics from our production PostgreSQL 17 database into the `export/` folder: `pg_stat_statements.csv`, `indexes.csv`, `tables.csv`, `activity.csv`, `settings.csv`, `schema.sql`, and our service's `deploy.yaml`. The database runs on 2 vCPU and 4 GiB of RAM and serves live traffic.

Review all of it and write two files:
- `audit.md`: every problem you find, most important first, each with the evidence from the export and the fix.
- `migration.sql`: the SQL to fix the problems that SQL can fix, safe to run on the live database.

Do not run anything; only read the export and write the two files.
