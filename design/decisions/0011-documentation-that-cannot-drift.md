# 0011 Documentation that cannot drift

Status: accepted. Recorded 2026-11-18.

## Decision

- Code shown in the guides (`SNIPPETS.md`, `GETTING_STARTED.md`) comes from `examples/snippets` and is
  compiled before the guides are written.
- Claims about the current architecture live in `design/rules.toml`, where `design/check.py` checks them.
  Reasons live in these decision records, which are dated and never edited, only superseded.
- Comments follow the rules in `AGENTS.md`: checked forms first, only about their own unit, no narration, no
  history.

## Why

A review on 2026-11-18 found stale comments and a design document that contradicted the code in several
places (compression listed as a non-goal after it was built; a rule for text conversions that was never
checked, and that 38 conversions did not follow). Prose that nothing checks drifts as soon as the code moves.

## Checked by

`examples/snippets/generate.sh --check` and `design/check.py`, both in CI. The comment rules are not checked.
