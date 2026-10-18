---
name: review-skill
description: Review one db-skills skill against the repository rules and current official documentation. Use before opening a PR for a new or changed skill.
argument-hint: <skill-name>
disable-model-invocation: true
---

# Review skill

Review `skills/$ARGUMENTS/` against `CLAUDE.md`. Report findings, most severe first; do not edit unless asked.

1. `bash scripts/validate.sh` and `bash scripts/test-examples.sh` pass on every supported version.
2. One decision; a position for each rule; the Why says what breaks, with a number where possible.
3. Every fact matches the official docs for the versions the examples run on (postgresql.org, dev.mysql.com, docs.aws.amazon.com). Version-specific rules carry an inline gate. Flag any claim sourced only from third-party material.
4. The good example proves the rule (a plan, a row count, an error) and the bad example shows a mistake people actually make, each marked `-- MISTAKE:`.
5. Schema changes are shown the online, non-blocking way first.
6. Workflow skills: every query in `queries/` is read-only, runs under a statement timeout, and does not expose row data or credentials in the report.
7. Checklist items can be answered from the SQL or the plan.
