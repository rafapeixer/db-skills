#!/usr/bin/env bash
# Throughput per connection: the same requests written two ways, measured
# with pgbench against PostgreSQL 17 sized like an RDS db.t4g.micro
# (2 vCPU, 1 GiB), from a client with network latency added.
#
#   bash benchmarks/throughput/run.sh [rtt, default 0.5ms] [seconds, default 20]
#
# Writes results.csv: scenario, variant, connections, tps, latency, lock waits.
set -euo pipefail
# Git Bash on Windows rewrites arguments that look like paths (/scripts/...).
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
rtt=${1:-0.5ms}
secs=${2:-20}
net=dbskills-tp
db=dbskills-tp-db
client=dbskills-tp-client

docker rm -f "$db" "$client" >/dev/null 2>&1 || true
docker network rm "$net" >/dev/null 2>&1 || true
docker network create "$net" >/dev/null

docker run -d --name "$db" --network "$net" --cpus 2 --memory 1g -e POSTGRES_PASSWORD=x \
  postgres:17 -c max_connections=100 -c shared_buffers=256MB >/dev/null
for _ in $(seq 1 60); do docker exec "$db" psql -U postgres -h 127.0.0.1 -c 'select 1' >/dev/null 2>&1 && break; sleep 1; done
docker exec "$db" psql -q -U postgres -c "CREATE DATABASE shop"
docker exec -i "$db" psql -q -v ON_ERROR_STOP=1 -U postgres -d shop <setup.sql

# Client: pgbench with iproute2, latency added on its network interface.
docker run -d --name "$client" --network "$net" --cap-add NET_ADMIN -e PGPASSWORD=x \
  --entrypoint sleep postgres:17 infinity >/dev/null
docker exec "$client" bash -c "apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq iproute2 >/dev/null 2>&1 && tc qdisc add dev eth0 root netem delay $rtt"
docker cp scripts "$client":/scripts >/dev/null

echo "scenario,variant,connections,tps,tps_per_connection,latency_ms,avg_sessions_waiting_on_locks" >results.csv
for scenario in page write queue counter; do
  for variant in naive good; do
    for conns in 4 16 64; do
      # Sample how many sessions wait on a lock while pgbench runs.
      (
        for _ in $(seq 1 $((secs * 2))); do
          docker exec "$db" psql -tAq -U postgres -d shop -c \
            "SELECT count(*) FROM pg_stat_activity WHERE datname = 'shop' AND wait_event_type = 'Lock'" 2>/dev/null
          sleep 0.5
        done
      ) >lockwaits.tmp &
      sampler=$!
      outp=$(docker exec "$client" pgbench -n -M prepared -c "$conns" -j "$((conns < 8 ? conns : 8))" -T "$secs" \
        -h "$db" -U postgres -f "/scripts/$scenario-$variant.sql" shop 2>&1)
      wait $sampler 2>/dev/null || true
      tps=$(sed -n 's/^tps = \([0-9.]*\).*/\1/p' <<<"$outp" | head -1)
      lat=$(sed -n 's/^latency average = \([0-9.]*\) ms/\1/p' <<<"$outp")
      waits=$(awk '{ s += $1; n++ } END { if (n) printf "%.1f", s / n; else print 0 }' lockwaits.tmp)
      per=$(awk -v t="$tps" -v c="$conns" 'BEGIN { printf "%.0f", t / c }')
      echo "$scenario,$variant,$conns,$tps,$per,$lat,$waits" | tee -a results.csv
    done
  done
done
rm -f lockwaits.tmp
docker rm -f "$db" "$client" >/dev/null
docker network rm "$net" >/dev/null
