# Contributing

**English** | [Português](CONTRIBUTING.pt-BR.md)

## Changing a rule

1. Open an issue: which rule, what breaks when people follow it, what it should say, and the official source.
2. Once agreed, one PR updates the rule, the examples and the checklist together.
3. Never weaken a rule to fit a bad example. Fix the example.

## Adding a skill

1. Decision skills are named `pg-<decision>` or `mysql-<decision>`; workflow skills `db-<workflow>`.
2. Start from [templates/SKILL.template.md](templates/SKILL.template.md) or [templates/WORKFLOW.template.md](templates/WORKFLOW.template.md).
3. Decision skills need `examples/good/test.sql` and `examples/bad/test.sql`. Each creates its schema, loads enough data for realistic plans, and asserts the outcome with the helpers in `scripts/lib/`.
4. Workflow skills keep every query in `queries/<engine>/*.sql`, read-only.
5. Every fact comes from official documentation (postgresql.org, dev.mysql.com, docs.aws.amazon.com) and is cited.
6. Add the skill to both `README.md` and `README.pt-BR.md`.

## Local checks

Requires Docker.

```bash
bash scripts/validate.sh                            # format, excerpts, read-only queries, README index
bash scripts/test-examples.sh                       # every example on every supported version
ONLY=skills/pg-indexing bash scripts/test-examples.sh   # one skill
```

## Commits and PRs

- One skill per PR, one logical change per commit: `skill(pg-indexing): add rule on covering indexes`.
- README and CONTRIBUTING changes update both languages in the same commit.
- When you check or change a skill's facts, set `metadata.verified` to that date.
