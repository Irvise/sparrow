#!/usr/bin/env bash
# Proves every crate with SPARK code (silver: no run-time errors). Fails on any unproved check. Needs gnatprove
# on the PATH (alr install gnatprove). Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

for crate in sparrow_core sparrow_io sparrow_crypto sparrow_json sparrow_jwt sparrow_postgres sparrow_http sparrow_valkey \
             sparrow_client; do
  echo "== $crate"
  (cd "$crate" && alr -n exec -- gnatprove -P "$crate.gpr" --level=2 --mode=silver -j0 --checks-as-errors=on \
     --warnings=error --quiet)
done
