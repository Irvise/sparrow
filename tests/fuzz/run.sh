#!/usr/bin/env bash
# Builds the fuzz targets with coverage instrumentation and runs each one for a while.
#
#   ./run.sh                       every target, 60 seconds each
#   ./run.sh 600 json jwt          the named targets, 600 seconds each
#
# Needs clang's libFuzzer runtime (libclang_rt.fuzzer_no_main) and objcopy. Linux only. Corpora grow in
# corpus/<target> (seeded from seeds/<target>); a failing input is saved as crash-<hash> here, and re-run
# with: bin/fuzz_<target> crash-<hash>
set -euo pipefail
cd "$(dirname "$0")"

seconds=${1:-60}
shift || true
targets=("$@")
[ ${#targets[@]} -eq 0 ] && targets=(http_request http_response http_2 multipart websocket_frames json jwt valkey_replies compression)

# libFuzzer without its main, with its stub of __sanitizer_cov_trace_pc made weak so src/coverage.c's counts.
runtime=$(clang -print-runtime-dir)
archive=""
for candidate in "$runtime/libclang_rt.fuzzer_no_main.a" "$runtime/libclang_rt.fuzzer_no_main-x86_64.a"; do
  [ -f "$candidate" ] && archive=$candidate && break
done
[ -n "$archive" ] || { echo "no libclang_rt.fuzzer_no_main in $runtime" >&2; exit 1; }
mkdir -p lib
cp "$archive" lib/libfuzzer.a
objcopy --weaken-symbol=__sanitizer_cov_trace_pc lib/libfuzzer.a

# Every crate instrumented and with its contracts checked; the validation profile keeps these objects apart
# from the ordinary builds'.
export ADAFLAGS="-fsanitize-coverage=trace-pc,trace-cmp -gnata"
alr -n build --profiles='*=validation'

status=0
for target in "${targets[@]}"; do
  echo "== $target ($seconds s)"
  mkdir -p "corpus/$target"
  if ! "bin/fuzz_$target" -max_total_time="$seconds" -max_len=8192 -timeout=10 -rss_limit_mb=2048 \
       -print_final_stats=1 "corpus/$target" "seeds/$target" 2>"corpus/$target.log"; then
    status=1
    grep -E 'fuzz:|ERROR|Test unit written' "corpus/$target.log" || tail -20 "corpus/$target.log"
  fi
  grep -E '^stat::number_of_executed_units|^stat::new_units_added' "corpus/$target.log" | tr '\n' ' '
  echo
done
exit $status
