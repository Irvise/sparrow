# 0004 Code that reads a client's bytes is proved

Status: accepted. Recorded 2026-11-18 from the project's development history and the code.

## Decision

Every unit that reads bytes from a client or a server Sparrow talks to is SPARK, proved free of run-time
errors (silver), with every check proved and none justified. Parsers and decoders are total: bad input gives
`Valid = False` or a neutral value, never an exception. Exceptions are kept for the edges where a caller
cannot sensibly continue (a lost database connection, a refused constraint, a bad route pattern).

## Why

These units face hostile input. Proof covers every input, not the ones a test thought of. The parsers came
out of Sparrow's ancestor already proved, and proof is cheap where the code is a parser over a buffer.

## Consequences

- The server's tasks and queues are tested, not proved, and run under ThreadSanitizer (`tests/race.sh`).
- The parsers are also fuzzed (`tests/fuzz`), and the compressor is fuzzed against zlib.

## Checked by

`tests/prove.sh` (CI) proves the crates. `design/check.py`: `[proved]` keeps the listed units in SPARK, spec
and body, and fails when a crate holding SPARK code is missing from `tests/prove.sh`.
