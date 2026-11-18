# 0010 Performance is measured

Status: accepted. Recorded 2026-11-18 from the project's development history.

## Decision

A change on the server's hot path (accepting, parsing, routing, writing, logging, compression) is benchmarked
before and after with `tests/bench/run.sh`, and the numbers are reported with the change. Runs drift between
machines and days, so compare ratios within one session, not absolute numbers across sessions.

## Why

Sparrow is a performance-focused stack; a regression on the request path costs every user. The maintainer:
"we just need to make sure we keep performance in mind".

## Checked by

Not checked automatically: benchmarks on shared CI machines are too noisy to fail a build on.
