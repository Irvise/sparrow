# 0003 The crate split

Status: superseded by 0012 (2026-11-18). Recorded 2026-11-18 from the project's development history and the code.

## Decision

Two rules decide where a crate ends:

1. Every C library gets a crate of its own, so a program links only the libraries it uses.
2. A layer is split from the one below it only when that keeps something out: sparrow_io keeps sockets and
   the per-platform bodies out of sparrow_core (and so out of json, sqlite, postgres, templates and client);
   sparrow_open_telemetry keeps libcurl out of sparrow_http.

Interfaces that a store implements and the server consumes (Sparrow.Stores: session tables, rate-limit
buckets) live in sparrow_core, so sparrow_valkey does not depend on the server, nor the server on it.
sparrow_postgres declares its own abstract state (Sparrow.Postgres.Server) rather than borrowing sparrow_io's.

The crates come in two groups: libraries that stand alone (json, templates, sqlite, postgres, client, crypto,
jwt, s3, valkey), and the server in layers (core, io, http, open_telemetry).

## Why

The first plan was "take what you need: each crate usable alone". Reviewed on 2026-11-18, that held for the
libraries but not for the server layers, which nobody takes one at a time. Rather than merge crates, the
boundaries were kept where they keep a dependency out, and the two couplings that served nothing were removed
(valkey on http, postgres on io).

## Consequences

- sparrow_http needs OpenSSL even for plain HTTP (sessions, WebSockets, randomness and TLS all use it).
- A Valkey or Postgres user builds no server code.

## Checked by

`design/check.py`: `[crates]` fixes each crate's Sparrow dependencies exactly, in alire.toml, in the project
file and in the units its sources `with`.
