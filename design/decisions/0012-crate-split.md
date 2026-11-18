# 0012 The crate split, and what a dependency must earn

Status: accepted. Decided 2026-11-18. Supersedes 0003.

## Decision

Where a crate ends:

1. Every C library gets a crate of its own, so a program links only the libraries it uses.
2. A layer is split from the one below it only when that keeps something out: sparrow_io keeps sockets and
   the per-platform bodies out of sparrow_core (and so out of every library built on core);
   sparrow_open_telemetry keeps libcurl out of sparrow_http.

What a dependency must earn: a crate depends on another only for behavior it cannot provide itself. Borrowing a
type or a SPARK state from another crate is not a reason. A unit that needs a handle or an abstract state for
what it touches declares its own, and its callers convert at the call:

- Sparrow.Stores in sparrow_core holds the interfaces a store implements and the server consumes (sessions,
  rate-limit buckets), so sparrow_valkey and sparrow_http do not depend on each other.
- Sparrow.Postgres declares its abstract state Server.
- Sparrow.Tls declares its own socket handle type (Socket_Handle) and abstract state (Network), so
  sparrow_crypto depends on sparrow_core alone.
- sparrow_s3 reads the clock and the environment through the Ada standard library, not sparrow_io.

The crates come in two groups: libraries that stand alone (json, templates, sqlite, postgres, client, crypto,
jwt, s3, valkey), and the server in layers (core, io, http, open_telemetry).

## Why

0003 recorded the dependency graph as it stood, and check.py then froze it. It caught dependencies added
later, not ones that were never earned. Asked why sparrow_crypto depended on sparrow_io, the answer was one
package: Sparrow.Tls took sparrow_io's descriptor type and named its SPARK state, and for that every user of
crypto (jwt, s3) built the socket layer. sparrow_s3 depended on sparrow_io for a clock reading and two
environment variables. The same pattern had already been removed from sparrow_postgres.

## Consequences

- sparrow_crypto depends on sparrow_core only; so sparrow_jwt builds no socket code, and sparrow_s3 none either.
- sparrow_http and sparrow_valkey convert their descriptor to Tls.Socket_Handle where they start TLS.
- The prover no longer knows that TLS and plain socket calls act on the same system state. Both states are
  external and synchronous, so it assumed nothing about their order before either; silver proofs are
  unaffected.
- Publishing has one stage fewer: crypto publishes beside io.

## Checked by

`design/check.py`: `[crates]` fixes each crate's Sparrow dependencies exactly, in alire.toml, in the project
file and in the units its sources `with`. Not checked: whether a dependency is earned. When adding one to
`[crates]`, name in the change what the crate uses from it.
