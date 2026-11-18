#!/bin/bash
# Benchmarks Sparrow's demo_server against an AWS hello server on the same machine. See README.md.
#
#   tests/bench/run.sh            Sparrow and AWS, every scenario
#   tests/bench/run.sh sparrow    Sparrow only (no AWS build needed)
#   tests/bench/run.sh log        only what the access log costs, writing to a file and to a pipe
#
# Environment: SECONDS_PER_RUN (default 10), SERVER_CPUS (default first half), LOAD_CPUS (default second half).
set -u
BENCH=$(cd "$(dirname "$0")" && pwd)
TESTS=$(dirname "$BENCH")
ONLY=${1:-all}
RUN_TIME=${SECONDS_PER_RUN:-10}
CPUS=$(nproc)
HALF=$((CPUS / 2))
SERVER_CPUS=${SERVER_CPUS:-0-$((HALF - 1))}
LOAD_CPUS=${LOAD_CPUS:-$HALF-$((CPUS - 1))}
THREADS=$HALF

ulimit -n "$(ulimit -Hn)" 2>/dev/null

# The load generator.
if [ ! -x "$BENCH/load" ] || [ "$BENCH/load.c" -nt "$BENCH/load" ]; then
   gcc -O2 -pthread -o "$BENCH/load" "$BENCH/load.c" || exit 1
fi

# The servers. AWS 25.2 does not build with GNAT 16, so its crate uses GNAT 13 (selected for that crate only).
(cd "$TESTS" && alr -n build --release >/dev/null 2>&1) || { echo "building demo_server failed"; exit 1; }
if [ "$ONLY" = all ] && [ ! -x "$BENCH/aws_hello/bin/aws_hello" ]; then
   (cd "$BENCH/aws_hello" \
      && alr -n toolchain --select --local gnat_native=13.2.1 gprbuild >/dev/null \
      && alr -n update >/dev/null 2>&1 \
      && alr -n build --release >/dev/null 2>&1) || { echo "building aws_hello failed"; exit 1; }
fi

LOAD="taskset -c $LOAD_CPUS $BENCH/load"
LOG=$(mktemp)
trap 'pkill -x demo_server; pkill -x aws_hello; rm -f "$LOG"' EXIT

start_sparrow() {   # access log on|off, and "pipe" to send standard error through a pipe instead of to a file
   if [ "${2:-file}" = pipe ]; then
      (cd "$TESTS" && REACTORS=$HALF WORKERS=$((HALF * 2)) ACCESS_LOG=$1 \
         taskset -c "$SERVER_CPUS" bin/demo_server 2>&1 >/dev/null | cat >/dev/null &)
   else
      (cd "$TESTS" && REACTORS=$HALF WORKERS=$((HALF * 2)) ACCESS_LOG=$1 \
         taskset -c "$SERVER_CPUS" bin/demo_server >/dev/null 2>"$LOG" &)
   fi
   sleep 0.7
}
start_aws() {       # Max_Connection
   (MAX=$1 taskset -c "$SERVER_CPUS" "$BENCH/aws_hello/bin/aws_hello" >/dev/null 2>&1 &)
   sleep 0.7
}
stop_all() { pkill -x demo_server; pkill -x aws_hello; sleep 0.5; }

line() { printf "%-30s %-34s " "$1" "$2"; }

scenario() {        # title connections depth aws-max with-worker-route
   local title=$1 connections=$2 depth=$3 aws_max=$4 worker=$5
   start_sparrow off
   line "$title" "sparrow /hello (reactor)"; $LOAD 18476 /hello "$THREADS" "$connections" "$RUN_TIME" "$depth"
   if [ "$worker" = yes ]; then
      line "$title" "sparrow /who/x (worker)"; $LOAD 18476 /who/x "$THREADS" "$connections" "$RUN_TIME" "$depth"
   fi
   stop_all
   if [ "$ONLY" != sparrow ]; then
      start_aws "$aws_max"
      line "$title" "aws (Max_Connection $aws_max)"; $LOAD 18477 /hello "$THREADS" "$connections" "$RUN_TIME" "$depth"
      stop_all
   fi
}

echo "servers on CPUs $SERVER_CPUS, load on CPUs $LOAD_CPUS, $RUN_TIME s per run"
if [ "$ONLY" != log ]; then
   scenario "64 conns, no pipelining"   64   1  64   yes
   scenario "64 conns, pipelining 16"   64   16 64   no
   scenario "1000 conns, no pipelining" 1000 1  1000 yes
fi

# What the access log costs, written to a real file and through a pipe.
for target in file pipe; do
   for mode in off on; do
      start_sparrow "$mode" "$target"
      line "64 conns, no pipelining" "sparrow /hello, log $mode, $target"
      $LOAD 18476 /hello "$THREADS" 64 "$RUN_TIME" 1
      stop_all
   done
done
