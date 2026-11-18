# 0007 Portable specs, per-platform bodies

Status: accepted. Recorded 2026-11-18 from the project's development history and the code.

## Decision

The specs of sparrow_io name no system call, constant or error number. Each has one body per platform
(`src/linux`: epoll; `src/bsd`: kqueue; `src/windows`: WSAPoll), chosen by the crate's project file. Failures
are values (`Error_Kind`), never `errno`. Linux is the platform tuned for; the others must be correct, not
fastest. Windows is a development target.

## Why

Servers run on Linux and the BSDs; developers work on all three. Specs that only promise what every
platform does keep the server's code free of platform cases.

## Checked by

`design/check.py`: `[portable_specs]` keeps C bindings out of the specs at the top of `sparrow_io/src`.
CI builds and tests on Linux, macOS and Windows.
