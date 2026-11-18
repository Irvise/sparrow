# 0006 Who owns what: reactors, workers, connections

Status: accepted. Recorded 2026-11-18 from the project's development history and the code.

## Decision

- A reactor owns its connections. Every other task reaches them only by posting to the reactor's mailbox, so
  nothing else locks them, and what one task sends to one connection arrives in order.
- A route runs its handler `On_Worker` (the default; it may block) or `On_Reactor` (it must never block).
- A database or Valkey connection belongs to one task. A server keeps one per worker, opened by the worker
  hooks: no pool and no locks. The shared stores (Valkey sessions and limits) lend pooled connections.
- No middleware chain: shared steps (authentication, logging) are procedures handlers call.

## Why

Ownership by one task is what lets the server run without locks on its hot path, and keeps handler code
plain, blocking Ada.

## Checked by

Not checked. Candidates: limited connection types (no copies between tasks); a test-build assertion that a
connection is used by the task that opened it; a lint that `On_Reactor` handlers call no blocking unit.
