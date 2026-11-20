#!/usr/bin/env bash
# Builds and runs every test program. Run from anywhere.
set -uo pipefail
shopt -s nullglob
cd "$(dirname "$0")"

./make_cert.sh || exit 1
alr -n build || exit 1

# GNAT 14 on macOS links some run-path entries twice, and macOS 26's loader refuses a program that has a
# duplicate: keep the first of each, and sign the program again (arm64 runs only signed code).
if [ "$(uname -s)" = Darwin ]; then
  for program in bin/*; do
    otool -l "$program" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | sort | uniq -d |
      while read -r path; do
        while [ "$(otool -l "$program" | grep -c "path $path ")" -gt 1 ]; do
          install_name_tool -delete_rpath "$path" "$program" 2>/dev/null || break
        done
        codesign --force --sign - "$program"
      done
  done
fi

status=0
for test in bin/*_tests bin/*_tests.exe; do
  "$test" || status=1
done
exit $status
