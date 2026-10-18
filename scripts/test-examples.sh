#!/usr/bin/env bash
# Runs every example against real databases in Docker.
#
#   bash scripts/test-examples.sh            # all supported versions
#   PG_VERSIONS=18 bash scripts/test-examples.sh
#
# Each example gets a fresh database with the helpers from scripts/lib
# loaded, then its test.sql runs with errors fatal. Good and bad examples
# both have to run cleanly: a bad example's assertions describe the bad
# outcome, so a bad example that stops showing its mistake also fails.
set -uo pipefail
cd "$(dirname "$0")/.."

# Oldest supported major that RDS offers, and the newest major.
PG_VERSIONS=${PG_VERSIONS:-"15 18"}
# Both LTS lines: 8.4 (the floor) and 9.7.
MYSQL_VERSIONS=${MYSQL_VERSIONS:-"8.4 9.7"}

errors=0
fail() {
  echo "FAIL $1"
  errors=$((errors + 1))
}

shopt -s nullglob
# ONLY=skills/pg-indexing limits the run to one skill.
only=${ONLY:-skills/*}
only=${only%/}
pg_examples=($only/examples/*/test.sql $only/queries/pg/*.sql)
mysql_examples=($only/examples/*/test.sql $only/queries/mysql/*.sql)
# Decision examples run on their own engine; workflow queries on theirs.
pg_examples=($(printf '%s\n' "${pg_examples[@]}" | grep -E '^skills/(pg-[^/]+/examples|db-[^/]+/queries/pg)/' || true))
mysql_examples=($(printf '%s\n' "${mysql_examples[@]}" | grep -E '^skills/(mysql-[^/]+/examples|db-[^/]+/queries/mysql)/' || true))
# Unique container names, so parallel runs never touch each other.
run_id=$$

wait_for() { # name, command...
  local name=$1
  shift
  for _ in $(seq 1 90); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "FAIL $name never became ready"
  docker logs "$name" 2>&1 | tail -20
  return 1
}

if [ ${#pg_examples[@]} -gt 0 ]; then
  for v in $PG_VERSIONS; do
    c=dbskills-pg-$v-$run_id
    docker rm -f "$c" >/dev/null 2>&1
    docker run -d --name "$c" -e POSTGRES_PASSWORD=dbskills "postgres:$v" -c shared_preload_libraries=pg_stat_statements >/dev/null
    wait_for "$c" docker exec "$c" psql -U postgres -h 127.0.0.1 -c 'select 1' || { errors=$((errors + 1)); continue; }
    for f in "${pg_examples[@]}"; do
      db=ex_$RANDOM$RANDOM
      docker exec "$c" createdb -U postgres "$db"
      if cat scripts/lib/pg-helpers.sql "$f" | docker exec -i "$c" psql -q -v ON_ERROR_STOP=1 -U postgres -d "$db" >/tmp/dbskills-out-$run_id.txt 2>&1; then
        echo "ok   pg $v  $f"
      else
        fail "pg $v  $f"
        tail -15 /tmp/dbskills-out-$run_id.txt
      fi
      docker exec "$c" dropdb -U postgres "$db" >/dev/null 2>&1
    done
    docker rm -f "$c" >/dev/null
  done
fi

if [ ${#mysql_examples[@]} -gt 0 ]; then
  for v in $MYSQL_VERSIONS; do
    c=dbskills-mysql-$v-$run_id
    docker rm -f "$c" >/dev/null 2>&1
    docker run -d --name "$c" -e MYSQL_ROOT_PASSWORD=dbskills "mysql:$v" >/dev/null
    wait_for "$c" docker exec "$c" mysql -uroot -pdbskills -h 127.0.0.1 -e 'select 1' || { errors=$((errors + 1)); continue; }
    for f in "${mysql_examples[@]}"; do
      db=ex_$RANDOM$RANDOM
      docker exec "$c" mysql -uroot -pdbskills -e "CREATE DATABASE $db" 2>/dev/null
      if cat scripts/lib/mysql-helpers.sql "$f" | docker exec -i "$c" mysql --batch -uroot -pdbskills "$db" >/tmp/dbskills-out-$run_id.txt 2>&1; then
        echo "ok   mysql $v  $f"
      else
        fail "mysql $v  $f"
        grep -v "Using a password" /tmp/dbskills-out-$run_id.txt | tail -15
      fi
      docker exec "$c" mysql -uroot -pdbskills -e "DROP DATABASE $db" >/dev/null 2>&1
    done
    docker rm -f "$c" >/dev/null
  done
fi

if [ ${#pg_examples[@]} -eq 0 ] && [ ${#mysql_examples[@]} -eq 0 ]; then
  echo "no examples yet, nothing to test"
fi
if [ "$errors" -gt 0 ]; then
  echo "$errors problem(s) found"
  exit 1
fi
echo "ok"
