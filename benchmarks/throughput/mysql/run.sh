#!/usr/bin/env bash
# Throughput per connection, MySQL edition: the same requests as ../run.sh
# written two ways, measured with sysbench against MySQL 8.4 sized like an
# RDS db.t4g.micro (2 vCPU, 1 GiB), from a client with network latency added.
#
#   bash benchmarks/throughput/mysql/run.sh [rtt, default 0.5ms] [seconds, default 20]
#
# Writes results.csv: scenario, variant, connections, tps, latency, lock waits.
set -euo pipefail
# Git Bash on Windows rewrites arguments that look like paths (/scripts/...).
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
rtt=${1:-0.5ms}
secs=${2:-20}
net=dbskills-tpm
db=dbskills-tpm-db
client=dbskills-tpm-client

cleanup() {
  docker rm -f "$db" "$client" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -f lockwaits.tmp
}
cleanup
trap cleanup EXIT
docker network create "$net" >/dev/null

# RDS sets innodb_buffer_pool_size to {DBInstanceClassMemory*3/4}, and
# DBInstanceClassMemory is below the class's 1 GiB; 512M leaves the container
# room for connections and performance_schema. TLS is off, as in the
# PostgreSQL run, so both measure the same protocol work.
docker run -d --name "$db" --network "$net" --cpus 2 --memory 1g \
  -e MYSQL_ROOT_PASSWORD=x -e MYSQL_DATABASE=shop -e MYSQL_USER=bench -e MYSQL_PASSWORD=x \
  mysql:8.4 --innodb-buffer-pool-size=512M --max-connections=100 --tls-version= >/dev/null
sql() { docker exec "$db" mysql -uroot -px -h127.0.0.1 --get-server-public-key "$@" 2>/dev/null; }
# The entrypoint's initialising server has networking off, so a TCP login
# succeeds only on the final server.
for _ in $(seq 1 90); do sql -e 'SELECT 1' >/dev/null && break; sleep 1; done
docker exec -i "$db" mysql -uroot -px shop <setup.sql 2>/dev/null >/dev/null
# caching_sha2_password needs TLS or the server's RSA key for an account's
# first login; after one full login the server caches it and later logins
# (sysbench's) use the fast path without either.
docker exec "$db" mysql -ubench -px -h127.0.0.1 --get-server-public-key -e 'SELECT 1' >/dev/null 2>&1

# Client: sysbench with iproute2, latency added on its network interface.
docker run -d --name "$client" --network "$net" --cap-add NET_ADMIN \
  --entrypoint sleep ubuntu:24.04 infinity >/dev/null
docker exec "$client" bash -c "apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sysbench iproute2 >/dev/null 2>&1 && tc qdisc add dev eth0 root netem delay $rtt"
docker cp scripts "$client":/scripts >/dev/null

echo "scenario,variant,connections,tps,tps_per_connection,latency_ms,avg_sessions_waiting_on_locks" >results.csv
for scenario in page write queue counter; do
  for variant in naive good; do
    for conns in 4 16 64; do
      # Sample how many transactions wait on a row lock while sysbench runs.
      (
        for _ in $(seq 1 $((secs * 2))); do
          sql -N -e "SELECT COUNT(DISTINCT REQUESTING_ENGINE_TRANSACTION_ID) FROM performance_schema.data_lock_waits"
          sleep 0.5
        done
      ) >lockwaits.tmp &
      sampler=$!
      # Server-side prepared statements (--db-ps-mode=auto is the default);
      # sysbench retries an event after a deadlock or lock wait timeout and
      # counts it under "ignored errors".
      outp=$(docker exec "$client" sysbench --db-driver=mysql --db-ps-mode=auto \
        --mysql-host="$db" --mysql-user=bench --mysql-password=x --mysql-db=shop \
        --threads="$conns" --time="$secs" "/scripts/$scenario-$variant.lua" run 2>&1)
      wait $sampler 2>/dev/null || true
      tps=$(sed -n 's/^ *transactions: *[0-9]* *(\([0-9.]*\) per sec.*/\1/p' <<<"$outp")
      lat=$(sed -n 's/^ *avg: *\([0-9.]*\)$/\1/p' <<<"$outp")
      errs=$(sed -n 's/^ *ignored errors: *\([0-9]*\).*/\1/p' <<<"$outp")
      if [ -z "$tps" ]; then echo "$outp" >&2; exit 1; fi
      waits=$(awk '{ s += $1; n++ } END { if (n) printf "%.1f", s / n; else print 0 }' lockwaits.tmp)
      per=$(awk -v t="$tps" -v c="$conns" 'BEGIN { printf "%.0f", t / c }')
      echo "$scenario,$variant,$conns,$tps,$per,$lat,$waits" >>results.csv
      echo "$scenario,$variant,$conns,$tps,$per,$lat,$waits (retried errors: ${errs:-0})"
    done
  done
done
