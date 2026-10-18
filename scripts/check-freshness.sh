#!/usr/bin/env bash
# Fails when a skill's facts were last verified more than MAX_AGE_DAYS ago.
# CI runs it on a schedule; re-check the facts against the official docs
# (postgresql.org, dev.mysql.com, docs.aws.amazon.com) and update
# metadata.verified.
set -euo pipefail
cd "$(dirname "$0")/.."

MAX_AGE_DAYS=183
errors=0
now=$(date -u +%s)
shopt -s nullglob
for file in skills/*/SKILL.md; do
  verified=$(sed -n 's/^  verified: *//p' "$file" | head -n 1)
  age=$(((now - $(date -u -d "$verified" +%s)) / 86400))
  if [ "$age" -gt "$MAX_AGE_DAYS" ]; then
    echo "FAIL $file: facts last verified $verified ($age days ago)"
    errors=$((errors + 1))
  fi
done
if [ "$errors" -gt 0 ]; then
  echo "$errors problem(s) found"
  exit 1
fi
echo "ok"
