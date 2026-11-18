#!/usr/bin/env bash
# Builds and runs every test program. Run from anywhere.
set -uo pipefail
shopt -s nullglob
cd "$(dirname "$0")"

./make_cert.sh || exit 1
alr -n build || exit 1

status=0
for test in bin/*_tests bin/*_tests.exe; do
  "$test" || status=1
done
exit $status
