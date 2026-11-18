# 0009 What Sparrow does not do

Status: accepted. Recorded 2026-11-18 from the project's development history.

## Decision

Sparrow leaves out:

- third-party sign-in (OIDC, "Sign in with ..."). Tokens from an identity provider are checked
  (Sparrow.Jwt.Key_Sets); signing users in is the application's, or a proxy's;
- an ORM or query builder, a common interface over the two databases, and mapping JSON onto records;
- HTTP/3, HTTP/2 server push and priorities, `Upgrade: h2c`, and WebSockets over HTTP/2.

## Why

Small enough to read, and nothing kept up that few would use. On sign-in modules, the maintainer: "if
someone wants to build it they can." On the rest: each costs more lines and upkeep than it saves; typed
statements, rows read by name and migration steps cover most of what an ORM would.

## Checked by

Not checked: scope is decided in review. Propose an addition by superseding this record.
