# CLAUDE.md

This file guides Claude Code (and any other coding agent) when working inside this repository.

## What this repository is

`db-skills` is a collection of **opinionated skills** that teach coding agents to design, query and operate PostgreSQL and MySQL efficiently, in any application language. It has two kinds of skills:

- **Decision skills** (`pg-*`, `mysql-*`): one design decision each, with a position, the reason, a good and a bad example that run against a real database in CI, and a review checklist.
- **Workflow skills** (`db-*`): read-only procedures a user runs against their own database (`/db-skills:db-audit`, `/db-skills:db-explain`, `/db-skills:db-connection-budget`). They inspect, explain and propose; they never change the database.

It is **not** a SQL tutorial and not a collection of generic tips. Every rule says "do it this way, because of this", and shows the cost of the alternative.

Primary audience: developers using Claude Code, Cursor, Codex or similar agents on applications backed by PostgreSQL or MySQL, including AWS RDS and Aurora. Secondary audience: engineers reading the skills directly.

Language-specific driver and pool rules (pgx, HikariCP, asyncpg) belong to the language repositories, such as [go-skills](https://github.com/rafapeixer/go-skills). This repository covers what the database sees: schema, SQL, transactions, migrations, connections and configuration.

## Repository structure

```
db-skills/
├── CLAUDE.md                    # this file
├── README.md / README.pt-BR.md  # what the repo is, install, index (English / Portuguese, kept in sync)
├── CONTRIBUTING.md / .pt-BR.md  # how to propose or change a skill
├── LICENSE                      # MIT
├── .claude-plugin/              # plugin and marketplace manifests; bump "version" on every release
├── .claude/                     # contributor tooling, not shipped to users
│
├── skills/
│   ├── pg-<decision>/           # PostgreSQL decision skill
│   │   ├── SKILL.md
│   │   └── examples/
│   │       ├── good/test.sql    # runs against Postgres, asserts the good outcome
│   │       └── bad/test.sql     # runs against Postgres, shows the mistake (assertions describe the bad outcome)
│   ├── mysql-<decision>/        # MySQL decision skill, same layout
│   └── db-<workflow>/           # read-only workflow skill (audit, explain, connection budget)
│       ├── SKILL.md
│       └── queries/             # the exact read-only SQL the workflow runs, per engine
│
├── templates/
│   ├── SKILL.template.md        # decision skills
│   └── WORKFLOW.template.md     # workflow skills
│
├── scripts/
│   ├── validate.sh              # format, versions, excerpts match examples, README indexes
│   ├── test-examples.sh         # runs every example against real Postgres and MySQL in Docker
│   ├── check-freshness.sh       # fails when a skill goes 6 months without re-verification
│   └── lib/                     # assertion helpers loaded into every example database
│
└── .github/workflows/           # ci.yml on every push and PR, freshness.yml monthly
```

## Supported versions

- **PostgreSQL:** examples run on the oldest supported major that RDS also offers and on the newest major (set in `scripts/test-examples.sh`). A rule that needs a newer major says so inline, for example "(PG 18+)".
- **MySQL:** examples run on the current LTS (8.4) and the newest Innovation release. A rule that needs an Innovation release says so inline.
- Raise the floors when a version reaches end of life: change them in `scripts/test-examples.sh`, this file and both READMEs in one commit.

## Decision skill format

YAML frontmatter, then Markdown:

```markdown
---
name: pg-indexing
description: Use when adding, reviewing or removing PostgreSQL indexes ...
metadata:
  verified: 2026-10-18
---
```

Required sections, in this order: **The decision**, **The rule** (4–8 numbered one-sentence rules), **Why**, **Good example**, **Bad example**, **Checklist** (5–10 `- [ ]` items), **When not to apply**. 100–400 lines. Never pad to reach the minimum; split a skill that passes the maximum.

## Workflow skill format

Frontmatter with `disable-model-invocation: true` (the user starts them), then: **Purpose**, **Safety** (read-only guarantees, what it never does), **Steps**, **Output** (the report format), **When not to use**. Every query the workflow runs lives in `queries/<engine>/*.sql` and is read-only.

## Rules for writing skills

- **One decision per skill.** If it needs "and", it is two skills.
- **Take a position.** "It depends" only when followed by on what, and what to do in each case.
- **Every claim needs a reason and, when possible, a number.** "Index the foreign key" is not enough; say what the delete does without it.
- **Examples run.** `good/test.sql` creates its schema, loads enough rows for the planner to behave like production (use `generate_series` or recursive CTEs), and asserts the outcome with the helpers in `scripts/lib`: for example that `EXPLAIN` uses the index, that a query returns the right rows, or that a statement fails with the expected error. `bad/test.sql` must also run without error; its assertions describe the bad outcome (a sequential scan, a lock wait, a duplicate row).
- **Bad examples are real mistakes**, the ones agents and junior developers actually make. Comment each with `-- MISTAKE: <what is wrong and what it costs>`.
- **Measure before claiming.** Numbers in a skill come from an example, a benchmark in this repository, or a cited primary source.
- **Safety first for anything that touches a live database.** Workflow skills are read-only. Decision skills that change schema show the online, non-blocking way first.
- **No filler.** Start at the decision.

### Language and tone

- Skills, templates and SQL comments are in **English**. README and CONTRIBUTING are bilingual (English and pt-BR) and change together.
- Direct, plain, second person.

### Changing a rule

Open an issue first, explain what breaks, and update the rule, examples and checklist in the same PR. Never weaken a rule to fit a bad example.

## Guardrails, not prose

| Mistake | Caught by |
|---|---|
| Missing or misordered section, wrong counts, bad frontmatter | `validate.sh` |
| `SKILL.md` excerpt that is not in the tested examples | `validate.sh` |
| Example that fails on a supported database version | `test-examples.sh` |
| Workflow query that writes (`INSERT`, `UPDATE`, `DELETE`, DDL, `VACUUM`, `ANALYZE` without consent) | `validate.sh` (forbidden keywords in `queries/`) |
| Facts not re-verified for six months | `check-freshness.sh` |

When you add a rule a script could enforce, add the check in the same PR.
