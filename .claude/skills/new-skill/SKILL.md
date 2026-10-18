---
name: new-skill
description: Scaffold a new db-skills skill (pg-*, mysql-* decision skill or db-* workflow skill) from the templates, then validate and run its examples. Use when adding a skill to this repository.
argument-hint: <skill-name>
disable-model-invocation: true
---

# New skill

Create the skill `$ARGUMENTS` in this repository.

1. Stop if `skills/$ARGUMENTS/` exists, or if the name is not lowercase kebab-case starting with `pg-`, `mysql-` or `db-`.
2. Read `CLAUDE.md` and the matching template in `templates/`.
3. Decision skill (`pg-*`, `mysql-*`): write `SKILL.md` and `examples/good/test.sql` plus `examples/bad/test.sql`. Each test creates its own schema, loads enough rows for the planner to behave realistically, and asserts with the helpers in `scripts/lib/` (`assert_true`, `plan_has`, `assert_error` on Postgres; `assert_true`, `plan_has` with `EXPLAIN FORMAT=JSON INTO @plan` on MySQL). The bad example's assertions describe the bad outcome, and each mistake is marked `-- MISTAKE:`.
4. Workflow skill (`db-*`): write `SKILL.md` and `queries/<engine>/*.sql`. Queries are read-only; validate.sh rejects writes, DDL, maintenance commands and `EXPLAIN ANALYZE`.
5. Every fact (version, default, limit, behavior) comes from the official docs: postgresql.org, dev.mysql.com, docs.aws.amazon.com, or the tool's own docs. Cite the URL in the Why section.
6. Add the skill to both `README.md` and `README.pt-BR.md`.
7. Run `bash scripts/validate.sh` and `bash scripts/test-examples.sh`; fix everything they report.
