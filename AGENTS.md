# AGENTS.md

How to work in this repository, for coding agents and for people. Short on purpose: every line here is a rule.

## Ground rules

- Do not commit, push, tag or publish unless asked.
- Protocols are written in Ada/SPARK. C is linked only for OpenSSL, libpq, SQLite and the operating system.
  No C protocol libraries (libcurl, nghttp2, zlib, and the like).
- Cryptography is OpenSSL's. Never implement a primitive.
- No third-party sign-in modules (OIDC, "Sign in with ...").
- Changes on the server's hot path are benchmarked before and after.
- Ada 2022, lines of 120 columns at most (80 in `examples/snippets/src`), descriptive names.
- Examples stay simple. Each crate's README documents only that crate.

## Before calling a change done

```sh
tests/run.sh                              # every suite (start tests/*_server.sh for Postgres, Valkey, S3)
tests/prove.sh                            # SPARK proof; must exit 0
python3 design/check.py                   # the design rules in design/rules.toml
(cd examples && alr build)
examples/snippets/generate.sh --check     # every snippet compiles; SNIPPETS.md, GETTING_STARTED.md current
tests/fuzz/run.sh 300                     # when a parser or decoder changed
```

Say which of these ran, and what failed.

## Design

The architecture lives in `design/`: rules as data in `rules.toml`, checked by `check.py`, and the reasons in
`design/decisions/`. A change that breaks a rule either changes the code back or comes with a new decision
record and the updated rule. A new rule comes with its check, or is marked Not checked. Decision records are
never edited after they are accepted; supersede them.

## Comments

A comment is a claim nothing checks. It goes stale the moment the code it describes changes elsewhere, and a
wrong comment misleads more than a missing one. So:

1. **Prefer a checked form.** A contract (`Pre`, `Post`, `Global`, `Exceptional_Cases`) over a sentence. A
   named constant over a number in prose. A compiled example (`examples/snippets`) over an example in a comment.
   A test over a description of behavior.
2. **Describe only your own unit.** Never state another unit's sizes, features, users or behavior. Name the
   other unit or constant (`Pipe_Capacity`) instead of repeating what it holds.
3. **No narration in bodies.** Do not say what the code does. A body comment is one line of why, where the
   code cannot show it: a workaround, an RFC section, a proof hint, a non-obvious bound.
4. **No history.** No "now", "new", "moved", "used to", "changed from". Git holds history.
5. **No usage examples in specs.** They belong in `examples/snippets`, where they compile.
6. **Spec headers are short:** what the unit is for, and the obligations a caller cannot see in the
   declarations: which task may use it, whether it blocks, what it raises, what is safe to share.
7. **Changing behavior means checking its comments.** In the same change, search every crate for comments
   that mention the names or behavior you changed, and fix or delete them. When unsure whether a comment
   is still true, delete it.
8. **Documentation code compiles.** Code shown in `SNIPPETS.md` and `GETTING_STARTED.md` comes from
   `examples/snippets` through `generate.sh`. Never edit those two files by hand.

Comments written before these rules are brought in line when their unit is next changed.
