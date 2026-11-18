# 0013 Native protocols, the HTTP client included

Status: accepted. Decided 2026-11-18. Supersedes 0001.

## Decision

What Sparrow serves, what it sends as a client, and every format it reads from or writes for another party is
written in Ada, and proved where it reads untrusted bytes: the HTTP/1.1 parser, HTTP/2 framing, HPACK and flow
control, WebSocket frames, multipart, JSON, Mustache templates, RESP (Valkey), DEFLATE and gzip, and the
outbound HTTP/1.1 client (Sparrow.Client, its URLs and response heads in Sparrow.Client_Wire).

C is linked only where another project maintains something Sparrow should not: OpenSSL (cryptography and TLS,
see 0002), libpq (the PostgreSQL client), SQLite (the database engine) and the operating system.

## Why

The point of the stack is native, provable implementations of the protocols it speaks. 0001 made an exception
for libcurl, for outbound HTTP. Reviewed on 2026-11-18, the exception was not earned: the client used HTTP/1.1
features any server offers, every hard part of it was already in Sparrow (TLS with host checking, sockets with
time limits, a proved chunked decoder), and what libcurl added beyond that (HTTP/2, decompression, proxies) no
caller used. A C library on the path of every answer from another service is code that cannot be proved or
fuzzed with the rest, and one more system library for every user of sparrow_client, sparrow_s3 and
sparrow_open_telemetry.

The line for binding C stays where 0001 drew it: a moving target kept up by its owners (TLS, the Postgres wire
protocol with its authentication methods and failover, SQLite itself). HTTP/1.1 is a fixed format.

## Consequences

- sparrow_client depends on sparrow_io (sockets) and sparrow_crypto (TLS), and links no library of its own.
- The client speaks HTTP/1.1 only, asks for no compression, uses no proxy, and opens a connection per call.
  Adding any of these is a change to this record's scope, not a reason to bind libcurl again.
- The chunked decoder moved from sparrow_http to sparrow_core (Sparrow.Chunked): the server and the client
  share one proved decoder.
- The HTTP/2 server is still tested against an independent implementation: the tests run the curl program,
  whose HTTP/2 is nghttp2's, and skip where it is missing. Programs in tests/ may use C libraries and tools that
  the crates may not (zlib, the curl program).
- sparrow_open_telemetry no longer keeps a library out of sparrow_http, the reason 0012 gives for it.
  Whether it stays a separate crate is open.

## Checked by

`design/check.py`: `[c_linkage]` (which crates may bind C, and which libraries each links),
`[forbidden_libraries]` (no curl, zlib, nghttp2, brotli, zstd or hiredis anywhere), and `[proved]`
(Sparrow.Chunked and Sparrow.Client_Wire stay SPARK). `tests/prove.sh` proves them.
