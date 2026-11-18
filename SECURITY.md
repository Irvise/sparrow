# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

- **GitHub:** use "Report a vulnerability" on the repository's Security tab (private vulnerability reporting).
- **Email:** michael.hardeman@protonmail.com, with "Sparrow security" in the subject.

Include what you found, how to reproduce it (an input, a request, a small program), and the version or commit.
If you have found it with the fuzzers in `tests/fuzz`, attach the saved input.

## What happens next

| Step | Within |
|---|---|
| Acknowledgement of your report | 7 days |
| First assessment: confirmed or not, and how severe | 14 days |
| A fix released, or a plan with a date | 90 days |

We agree a disclosure date with you, normally when the fix is released. You are credited in the advisory and
the changelog unless you would rather not be.

## Supported versions

Sparrow is before 1.0. Security fixes go into the latest 0.x release only, so stay on it. From 1.0, the latest
minor release of the current major version will be supported.

## Scope

In scope: everything in this repository, including how Sparrow calls OpenSSL, libpq and SQLite.

Out of scope, but please still tell us so we can pass it on or work around it: flaws in those libraries
themselves (report them upstream as well), and in GNAT or its runtime.

Not vulnerabilities:
- Behaviour the documentation describes, such as the limits in `Sparrow.Http.Servers.Configuration`.
- Denial of service through traffic volume alone.
- Problems that need a malicious application, or someone who already controls the server.
- BREACH-style guessing of a secret from compressed response lengths, beyond what the documented padding
  makes harder: Sparrow pads gzip responses with 1–32 random bytes, which raises the number of requests
  such an attack needs but does not prevent it. Pages that echo request input next to a secret can turn
  compression off for themselves with `Cache-Control: no-transform` (see sparrow_http's README).

## How the code is checked

- **SPARK proof:** the parsers are proved free of run-time errors. They cover:
  - HTTP/1.1 heads, HTTP/2 frames and HPACK;
  - WebSocket frames;
  - routes, multipart and session envelopes;
  - `Accept-Encoding` and `Range` headers;
  - JSON, JWT, Valkey replies, IP addresses and PostgreSQL values.

  The gzip compressor is proved too: it writes nothing outside its output buffer, whatever the input.

  `tests/prove.sh` runs the proof.
- **Fuzzing:** `tests/fuzz/run.sh` fuzzes, with libFuzzer, the HTTP request parser, HTTP/2 sessions,
  multipart, WebSocket frames, JSON, JWT, Valkey replies and gzip compression (checked against zlib's
  decoder). It checks round-trip properties as well as crashes.
  CI runs it on every push and for longer each night.
- **Races:** `tests/race.sh` runs the server's tests and load under ThreadSanitizer, in CI too.
- **No hand-written cryptography:** all of it is OpenSSL's.
