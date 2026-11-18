# 0008 Toolchain and system libraries

Status: superseded by 0014 (2026-11-18). Recorded 2026-11-18 from the project's development history and the code.

## Decision

- Ada 2022, GNAT 13 or later, lines of 120 columns at most, descriptive names.
- System libraries: OpenSSL 3.0, libpq 16, libcurl 7.85 or later. Older ones are refused with a message
  saying what to update: OpenSSL and libpq when the program starts, libcurl at its first call.
- The crates are versioned and released together.

## Why

GNAT 13 is the oldest compiler CI builds and tests with. Alire cannot state a minimum version for a system
library, so the libraries are checked by the program itself.

## Checked by

`design/check.py`: `[toolchain]` checks every crate's manifest. CI builds with GNAT 13 to 16. The library
versions are checked by the crates themselves.
