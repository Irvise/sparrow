# 0005 Bytes and text are different types

Status: accepted. Recorded 2026-11-18 from the project's development history and the code.

## Decision

`String` is bytes: what sockets carry, digests, and everything a client sent until it has been checked.
`Sparrow.UTF8_String` is text: well-formed UTF-8. Bytes become text only through a checked conversion
(`Sparrow.Encoding.To_UTF8`) or a parser that checks (`Sparrow.Json.Parse`).

Ada allows the bare conversion `UTF8_String (Bytes)`, which checks nothing. It appears only in Sparrow, on
bytes Sparrow has validated or produced, with the reason on the same line or the line above, marked `UTF-8:`.

## Why

The compiler then keeps a digest out of a template and a request header out of a SQL text parameter unless
someone writes a conversion at that spot, where it can be reviewed.

A `Dynamic_Predicate` on the type would make the rule the compiler's, but slices are taken by bytes: every
slice passed on would need a proof or a re-scan. Not adopted.

## Consequences

When the rule was first checked (2026-11-18), 38 bare conversions had no written reason. They are counted
per file in `rules.toml` and may only fall. One of them is a real gap: session values read from a
`Session_Table` are returned as text without a UTF-8 check.

## Checked by

`design/check.py`: `[text_conversions]` fails on a new bare conversion without its reason.
