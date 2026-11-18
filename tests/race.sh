#!/usr/bin/env bash
# Builds the test programs with ThreadSanitizer and runs what exercises the server's tasks: the HTTP and HTTP/2
# suites (reactors, workers, mailboxes, streamed bodies, event streams), then the demo server under stress.py,
# plain and over TLS. Fails on any race report outside OpenSSL (see tsan.supp).
#
# The build uses the validation profile, so its objects stay apart from the development ones; run.sh rebuilds
# the ordinary test programs afterwards. Linux, GNAT 13 or later with libtsan.
set -uo pipefail
cd "$(dirname "$0")"

./make_cert.sh || exit 1
ADAFLAGS="-fsanitize=thread -g" alr -n build --profiles='*=validation' -- -largs -fsanitize=thread || exit 1

export TSAN_OPTIONS="halt_on_error=0 exitcode=66 suppressions=$PWD/tsan.supp"
logs=$(mktemp -d)
status=0

for test in http_tests http_2_tests; do
  echo "== $test"
  bin/$test >"$logs/$test.log" 2>&1 || status=1
  grep -E 'passed' "$logs/$test.log"
done

for mode in plain tls; do
  echo "== demo_server under stress.py ($mode)"
  if [ $mode = tls ]; then TLS=1 bin/demo_server >"$logs/demo_$mode.log" 2>&1 & else bin/demo_server >"$logs/demo_$mode.log" 2>&1 & fi
  server=$!
  sleep 2
  python3 stress.py 100 200 $([ $mode = tls ] && echo tls) || status=1
  # HTTP/2: 3000 requests multiplexed over few connections, half on workers.
  scheme=$([ $mode = tls ] && echo https || echo http)
  codes=$(curl -sk -Z --parallel-max 100 $([ $mode = tls ] && echo --http2 || echo --http2-prior-knowledge) \
          -w '%{stderr}%{http_code} %{http_version}\n' "$scheme://localhost:18476/who/n[1-1500]" \
          "$scheme://localhost:18476/hello?[1-1500]" 2>&1 >/dev/null | sort | uniq -c)
  echo "h2: $codes"
  [ "$(echo "$codes" | grep -c '200 2')" -eq 1 ] && [ "$(echo "$codes" | wc -l)" -eq 1 ] || status=1
  kill -INT $server
  wait $server || status=1
done

reports=$(cat "$logs"/*.log | grep -c 'WARNING: ThreadSanitizer')
echo "race reports: $reports (logs in $logs)"
[ "$reports" -eq 0 ] || status=1
exit $status
