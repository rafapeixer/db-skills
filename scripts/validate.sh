#!/usr/bin/env bash
# Checks every skill against the format in CLAUDE.md:
#   decision skills (pg-*, mysql-*): frontmatter, the 7 sections in order,
#     length, rule and checklist counts, runnable examples, excerpts that
#     exist in the examples, presence in both READMEs;
#   workflow skills (db-*): frontmatter, their 5 sections, read-only queries.
set -euo pipefail
cd "$(dirname "$0")/.."

DECISION_SECTIONS=("The decision" "The rule" "Why" "Good example" "Bad example" "Checklist" "When not to apply")
WORKFLOW_SECTIONS=("Purpose" "Safety" "Steps" "Output" "When not to use")
MIN_LINES=100
MAX_LINES=400
# Statements a workflow query must never contain: it inspects, it never changes.
FORBIDDEN='\b(INSERT|UPDATE|DELETE|MERGE|REPLACE|UPSERT|CREATE|ALTER|DROP|TRUNCATE|RENAME|GRANT|REVOKE|VACUUM|ANALYZE|REINDEX|CLUSTER|OPTIMIZE|COPY|LOAD|CALL|DO|LOCK|KILL|PG_TERMINATE_BACKEND|PG_CANCEL_BACKEND|PG_STAT_STATEMENTS_RESET|PG_STAT_RESET|FLUSH|PURGE|RESET)\b'

errors=0
fail() {
  echo "FAIL $1: $2"
  errors=$((errors + 1))
}

section_body() {
  awk -v title="## $2" '
    $0 == title { inside = 1; next }
    /^## / && inside { exit }
    inside { print }
  ' "$1"
}

check_frontmatter() { # skill file
  local skill=$1 file=$2
  if [ "$(head -n 1 "$file")" != "---" ]; then
    fail "$skill" "SKILL.md must start with YAML frontmatter (---)"
  fi
  # Claude Code fails to parse frontmatter with CRLF and loads the skill with no description.
  if [ "$(tr -d '\r' <"$file" | wc -c)" -ne "$(wc -c <"$file")" ]; then
    fail "$skill" "SKILL.md has CRLF line endings; use LF"
  fi
  frontmatter=$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$file")
  local name description verified
  name=$(printf '%s\n' "$frontmatter" | sed -n 's/^name: *//p')
  description=$(printf '%s\n' "$frontmatter" | sed -n 's/^description: *//p')
  verified=$(printf '%s\n' "$frontmatter" | sed -n 's/^  verified: *//p')
  [ "$name" = "$skill" ] || fail "$skill" "frontmatter name '$name' does not match folder name"
  [[ "$description" == "Use when "* ]] || fail "$skill" "description must start with 'Use when '"
  [ ${#description} -le 1024 ] || fail "$skill" "description is longer than 1024 characters"
  [[ "$verified" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "$skill" "frontmatter needs metadata.verified: YYYY-MM-DD"
}

check_sections() { # skill file expected...
  local skill=$1 file=$2
  shift 2
  local actual expected
  actual=$(grep '^## ' "$file" | sed 's/^## //')
  expected=$(printf '%s\n' "$@")
  [ "$actual" = "$expected" ] || fail "$skill" "sections must be, in order: $(printf '%s, ' "$@" | sed 's/, $//')"
}

shopt -s nullglob
for dir in skills/*/; do
  skill=$(basename "$dir")
  file="$dir/SKILL.md"
  [ -f "$file" ] || { fail "$skill" "missing SKILL.md"; continue; }
  check_frontmatter "$skill" "$file"

  case "$skill" in
  pg-* | mysql-*)
    check_sections "$skill" "$file" "${DECISION_SECTIONS[@]}"
    lines=$(wc -l <"$file" | tr -d ' ')
    { [ "$lines" -ge "$MIN_LINES" ] && [ "$lines" -le "$MAX_LINES" ]; } || fail "$skill" "SKILL.md has $lines lines, expected $MIN_LINES to $MAX_LINES"
    rules=$(section_body "$file" "The rule" | grep -cE '^[0-9]+\. ' || true)
    { [ "$rules" -ge 4 ] && [ "$rules" -le 8 ]; } || fail "$skill" "The rule has $rules numbered rules, expected 4 to 8"
    items=$(section_body "$file" "Checklist" | grep -c '^- \[ \] ' || true)
    { [ "$items" -ge 5 ] && [ "$items" -le 10 ]; } || fail "$skill" "Checklist has $items items, expected 5 to 10"
    exceptions=$(section_body "$file" "When not to apply" | grep -c '^- ' || true)
    [ "$exceptions" -ge 1 ] || fail "$skill" "When not to apply has no cases"
    for kind in good bad; do
      [ -f "$dir/examples/$kind/test.sql" ] || { fail "$skill" "missing examples/$kind/test.sql"; continue; }
      [ "$kind" = good ] && section="Good example" || section="Bad example"
      corpus=$(cat "$dir"/examples/$kind/*.sql | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      while IFS= read -r line; do
        grep -Fxq -- "$line" <<<"$corpus" || fail "$skill" "$section excerpt line not found in examples/$kind: $line"
      done < <(section_body "$file" "$section" | awk '
        /^```sql$/ { inside = 1; next }
        /^```/ { inside = 0; next }
        inside { gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "" && $0 != "...") print }
      ')
    done
    for readme in README.md README.pt-BR.md; do
      grep -q "(skills/$skill/SKILL.md)" "$readme" || fail "$skill" "not listed in $readme"
    done
    ;;
  db-*)
    check_sections "$skill" "$file" "${WORKFLOW_SECTIONS[@]}"
    grep -q '^disable-model-invocation: true$' "$file" || fail "$skill" "workflow skills need disable-model-invocation: true"
    queries=("$dir"queries/*/*.sql)
    [ ${#queries[@]} -gt 0 ] || fail "$skill" "no queries/<engine>/*.sql"
    for q in "${queries[@]}"; do
      # Strip comments and string literals before looking for write statements.
      body=$(sed -e 's/--.*$//' "$q" | tr '\n' ' ' | sed -e "s/'[^']*'//g" -e 's#/\*[^*]*\*/##g')
      if grep -qiE "$FORBIDDEN" <<<"$body"; then
        fail "$skill" "$(basename "$q") contains a write or maintenance statement: $(grep -oiE "$FORBIDDEN" <<<"$body" | head -1)"
      fi
      grep -qiE '\bEXPLAIN[[:space:]]*\([^)]*\bANALY[SZ]E\b' <<<"$body" && fail "$skill" "$(basename "$q") uses EXPLAIN ANALYZE, which executes the statement"
    done
    for readme in README.md README.pt-BR.md; do
      grep -q "(skills/$skill/SKILL.md)" "$readme" || fail "$skill" "not listed in $readme"
    done
    ;;
  *)
    fail "$skill" "skill folders must start with pg-, mysql- or db-"
    ;;
  esac
done

en=$(grep -c '^## ' README.md || true)
pt=$(grep -c '^## ' README.pt-BR.md || true)
[ "$en" = "$pt" ] || fail "README" "README.md has $en sections, README.pt-BR.md has $pt"

if [ "$errors" -gt 0 ]; then
  echo "$errors problem(s) found"
  exit 1
fi
echo "ok"
