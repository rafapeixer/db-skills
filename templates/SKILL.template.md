---
name: <pg-|mysql-><decision>
description: Use when <the concrete situation that should trigger this skill: designing X, writing Y, reviewing Z>. Covers <the 3 to 5 sub-topics in one line>.
metadata:
  verified: 2026-10-18
---

# <Skill title>

## The decision

<One paragraph. Name the decision, when it comes up, and what getting it wrong costs (latency, locks, CPU, storage, money). Start at the decision.>

## The rule

1. <One sentence. Imperative.>
2. <One sentence.>
3. <One sentence.>
4. <...>

<4 to 8 rules. Mark rules that need a newer version inline, e.g. "(PG 18+)" or "(MySQL 9.x)".>

## Why

<For each rule that is not obvious, what breaks without it, with a number from the example, a benchmark here, or the official docs (cite the URL).>

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
-- 5 to 15 lines copied from examples/good/test.sql.
```

<What the test asserts: the plan, the rows, the error it prevents.>

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- 5 to 15 lines copied from examples/bad/test.sql.
-- MISTAKE: <what is wrong and what it costs>
```

<The assertions in the bad example describe the bad outcome (a Seq Scan, a lock wait, a duplicate row), so the example fails if the mistake stops showing.>

## Checklist

When reviewing schema or SQL under this skill, confirm:

- [ ] <Yes/no question a reviewer can answer from the SQL or the plan.>
- [ ] <...>
- [ ] <...>
- [ ] <...>
- [ ] <...>

## When not to apply

- <A real case where the rule bends, and what to do instead.>
