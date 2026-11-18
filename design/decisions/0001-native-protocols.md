# 0001 Native protocols

Status: superseded by 0013 (2026-11-18). Recorded 2026-11-18 from the project's development history and the code.

## Decision

What Sparrow serves, and every format it reads from or writes for a client, is written in Ada, and proved
where it reads untrusted bytes: the HTTP/1.1 parser, HTTP/2 framing, HPACK and flow control, WebSocket frames,
multipart, JSON, Mustache templates, RESP (Valkey), DEFLATE and gzip.

C is linked only where another project maintains something Sparrow should not: OpenSSL (cryptography and TLS,
see 0002), libpq (the PostgreSQL client), SQLite (the database engine), libcurl (outbound HTTP) and the
operating system.

## Why

The point of the stack is native, provable server implementations. The maintainer, on HTTP/2: "do not use a c
library to implement http/2", and "we are trying to provide native http server implementations". A C codec
on the request path is code that cannot be proved, fuzzed in the same harness, or read in one language.

The line for binding C: a moving target kept up by its owners (TLS, the Postgres wire protocol with its
authentication methods and failover, SQLite itself). DEFLATE is a fixed format, so it is written here; RESP is
small and stable, so the Valkey client is native too.

## Consequences

- HTTP/2 was first planned over nghttp2, and compression was first left to a proxy. Both were reversed: the
  server speaks HTTP/2 and gzip itself.
- The PostgreSQL client began as Sparrow's own wire-protocol code and was replaced by libpq. The decoders of
  its results (Sparrow.Postgres_Wire) stay native and proved.
- zlib is linked only by the tests, as a reference decoder for the compressor's output.

## Checked by

`design/check.py`: `[c_linkage]` (which crates may bind C, and which libraries each links) and
`[forbidden_libraries]` (no zlib, nghttp2, brotli, zstd or hiredis anywhere).
