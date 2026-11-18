# 0014 Toolchain and system libraries

Status: accepted. Decided 2026-11-18. Supersedes 0008.

## Decision

- Ada 2022, GNAT 13 or later, lines of 120 columns at most, descriptive names.
- Each system library a crate links has a minimum version, which the crate checks itself: a program built
  against an older one is refused with a message saying what to update. The libraries are the ones
  `[c_linkage]` in `design/rules.toml` allows; their minimum versions are named where each crate checks them
  and in the top-level README.
- The crates are versioned and released together.

## Why

GNAT 13 is the oldest compiler CI builds and tests with. Alire cannot state a minimum version for a system
library, so the libraries are checked by the program itself.

0008 listed the libraries and their versions in the record. A list in a record goes stale when the code moves
(libcurl left with 0013), and records are not edited, so the list now lives where it is checked.

## Checked by

`design/check.py`: `[toolchain]` checks every crate's manifest. CI builds with GNAT 13 to 16. The library
versions are checked by the crates themselves.
