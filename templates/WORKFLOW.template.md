---
name: db-<workflow>
description: Use when <the user asks to ...>. Read-only: inspects <engine objects> and proposes changes without applying them.
disable-model-invocation: true
argument-hint: <what the user passes, e.g. a connection string variable or a query>
metadata:
  verified: 2026-10-18
---

# <Workflow title>

## Purpose

<One paragraph: what the user gets at the end and why it matters.>

## Safety

- Connect with a read-only role (see `queries/<engine>/00-session.sql`) and a statement timeout.
- Run only the queries in `queries/`; never write, never run DDL, never `EXPLAIN ANALYZE` a write.
- Show every proposed change as a migration file for the user to review; apply nothing.
- <Engine-specific notes: PII in query texts, replicas, locks.>

## Steps

1. <Detect the engine and version.>
2. <Run queries/... and collect results.>
3. <Interpret with the rules from the decision skills (link them by name).>
4. <Write the report.>

## Output

<The report format: findings ordered by impact, each with evidence, the decision skill it relates to, the proposed fix as a migration, and how to verify.>

## When not to use

- <Cases where this workflow does not fit and what to do instead.>
