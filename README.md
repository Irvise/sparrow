# Sparrow

A small web stack for Ada on Linux, macOS and Windows, as a set of Alire crates. Needs:
- GNAT 13 or later.
- OpenSSL 3.0 or later. Password hashes are Argon2id from 3.2, and scrypt before it.
- libpq 16 or later, for `sparrow_postgres`.
- libsqlite3, for `sparrow_sqlite`.
- Valkey 7.2 or later (or Redis 7), when `sparrow_valkey` is used.

A program built against older libraries refuses to start and says what to update.

New here? [GETTING_STARTED.md](GETTING_STARTED.md) installs the tools and builds a hello world;
[SNIPPETS.md](SNIPPETS.md) has short, copyable pieces for each feature.

The crates come in two groups.

**Libraries that stand alone.** Each is useful without a server and pulls in nothing more than it names: take
`sparrow_sqlite` and you link neither OpenSSL nor libpq.

| Crate | What it is | Sparrow crates it needs |
|---|---|---|
| [`sparrow_json`](sparrow_json) | Allocation-free JSON reader with paths and request checks, streaming writer | core |
| [`sparrow_templates`](sparrow_templates) | Mustache templates over a pluggable data source | core, json |
| [`sparrow_sqlite`](sparrow_sqlite) | Thin SQLite binding: rows by name, migrations | core |
| [`sparrow_postgres`](sparrow_postgres) | PostgreSQL client over libpq: one-call queries, rows by name, pipelines, migrations | core |
| [`sparrow_client`](sparrow_client) | Outbound HTTP/1.1 and HTTPS, for calling other services | core, io, crypto |
| [`sparrow_crypto`](sparrow_crypto) | OpenSSL bindings: hashes, HMAC, KDFs, Argon2id passwords, AEAD, Ed25519, randomness, TLS | core |
| [`sparrow_jwt`](sparrow_jwt) | JSON Web Tokens: HS256, and RS256, ES256 and EdDSA with keys from a JWKS | core, crypto, json |
| [`sparrow_s3`](sparrow_s3) | S3 and compatible object stores: put, get, delete, presigned URLs | core, crypto, client |
| [`sparrow_valkey`](sparrow_valkey) | Valkey and Redis client; sessions and rate limits shared by every server | core, io, crypto |

**The server, in layers.** These are not picked one by one: each layer exists to keep what it needs out of the
ones below it (sockets and platform code out of `sparrow_core`).

| Crate | What it is |
|---|---|
| [`sparrow_core`](sparrow_core) | Byte buffers, UTF-8 and number encoding, time formats, Base64, gzip, the store interfaces |
| [`sparrow_io`](sparrow_io) | Portable sockets, readiness events (epoll, kqueue, WSAPoll), clocks, structured logging (text or JSON), Prometheus metrics |
| [`sparrow_http`](sparrow_http) | Non-blocking HTTP/1.1, HTTP/2 and HTTPS server and router; static files, streaming responses, Server-Sent Events, WebSockets, sealed-cookie sessions with CSRF tokens, CORS, multipart uploads; request ids, W3C trace context, an access log, metrics and health routes |
| [`sparrow_open_telemetry`](sparrow_open_telemetry) | Trace export to OpenTelemetry collectors (OTLP over HTTP), for `sparrow_http` |

**Status:** every crate builds and passes its tests on Linux (x86-64) with GNAT 13.2 and 16.1.
[CI](.github/workflows/ci.yml) runs the suite on Linux, macOS and Windows with GNAT 13 to 16, and proves the
SPARK code. The FreeBSD body of `sparrow_io` compiles but has never run.

## Examples

[`examples/`](examples) is one crate with eight programs, each a few hundred lines at most:

| Example | Shows |
|---|---|
| `rest_service` | A JSON REST API over SQLite, with JWT bearer tokens for writes |
| `static_site` | A static web server: one route, `Sparrow.Http.Static` |
| `todo_app` | Server-rendered Mustache templates with htmx, SQLite, static assets |
| `blob_game` | Gobble, a real-time multiplayer blob arena with bots: a protected world pushed to every player over a WebSocket, a canvas client |
| `forum` | Register, log in, start threads and reply: sealed-cookie sessions, CSRF tokens, Argon2id, live updates over Server-Sent Events |
| `file_drop` | Drag-and-drop uploads streamed to disk, or straight to S3 with presigned URLs; live list over Server-Sent Events |
| `notes_api`, `token_issuer` | A JSON API over PostgreSQL that trusts EdDSA tokens from another service's JWKS |

```sh
cd examples && alr build && bin/blob_game    # then open http://localhost:8080/
```

## Tests

```sh
cd tests
./postgres_server.sh   # optional: a TLS Postgres in podman for the Postgres suite
./run.sh               # builds everything and runs every suite
./prove.sh             # SPARK proof of every crate that has proved code (needs gnatprove)
fuzz/run.sh 300        # libFuzzer on the parsers, 5 minutes each (needs clang's libFuzzer; Linux)
./race.sh              # the server's tests and load under ThreadSanitizer (Linux)
```

Security problems: see [SECURITY.md](SECURITY.md). Changes: [CHANGELOG.md](CHANGELOG.md). Releases:
[RELEASING.md](RELEASING.md).

MIT licensed.
