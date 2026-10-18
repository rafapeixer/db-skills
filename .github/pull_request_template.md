## What changes

<!-- One skill per PR. Name the skill and the rule(s) added or changed. -->

## What breaks without it

<!-- The concrete failure this prevents: a bug, an outage, a CVE, a measured cost. "I prefer it" is not enough. -->

## Sources

<!-- Official sources only for every fact: postgresql.org, dev.mysql.com, docs.aws.amazon.com, or the tool's own docs. -->

## Checklist

- [ ] `bash scripts/validate.sh` and `bash scripts/test-examples.sh` pass locally.
- [ ] Good example shows the rule; bad example shows a real mistake, marked `-- MISTAKE:`.
- [ ] Inline excerpts in `SKILL.md` were copied from the example files.
- [ ] Rules that need a newer database version carry an inline gate, e.g. "(PG 18+)" or "(MySQL 9.x)".
- [ ] `metadata.verified` is today's date if facts were checked or changed.
- [ ] `README.md` and `README.pt-BR.md` (and `CONTRIBUTING*` if touched) are updated together.
- [ ] If an existing rule changed: there is an issue, and the examples and checklist changed in this PR too.
