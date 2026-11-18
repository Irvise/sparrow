# Design

The architecture of Sparrow, kept where it cannot quietly go out of date:

- **`rules.toml`**: what must be true of the tree now, as data.
- **`check.py`**: checks the tree against `rules.toml`. Run it before calling a change done; CI runs it too.
- **`decisions/`**: why each rule exists. One dated record per decision, never edited once accepted, only
  superseded by a newer one.

```sh
python3 design/check.py            # Python 3.11 or later; exit status 0 when every rule holds
```

## Decisions

| Record | Decision | Checked by |
|---|---|---|
| [0013](decisions/0013-native-protocols.md) | Protocols and formats, the HTTP client included, are written in Ada; C only where others maintain it | `check.py` `[c_linkage]`, `[forbidden_libraries]`, `[proved]` |
| [0002](decisions/0002-cryptography-from-openssl.md) | Cryptography from the system's OpenSSL only | `check.py` `[forbidden_libraries]`; no hand-written primitives: review |
| [0012](decisions/0012-crate-split.md) | A crate per C library; a dependency only for what a crate cannot do without it | `check.py` `[crates]`; whether a dependency is worth it: review |
| [0004](decisions/0004-proved-input-handling.md) | Code that reads a client's bytes is proved, and total | `tests/prove.sh`; `check.py` `[proved]` |
| [0005](decisions/0005-bytes-and-text.md) | Bytes and text are different types; bare conversions give their reason | `check.py` `[text_conversions]` |
| [0006](decisions/0006-task-ownership.md) | Reactors own connections; a connection belongs to one task | **Not checked** |
| [0007](decisions/0007-portability.md) | Portable specs, per-platform bodies | `check.py` `[portable_specs]`; CI on three systems |
| [0014](decisions/0014-toolchain.md) | Ada 2022, GNAT 13+, minimum system libraries | `check.py` `[toolchain]`; CI with GNAT 13 to 16 |
| [0009](decisions/0009-scope.md) | What Sparrow does not do | **Not checked**: review |
| [0010](decisions/0010-performance.md) | Hot-path changes are benchmarked | **Not checked**: `tests/bench/run.sh` by hand |
| [0011](decisions/0011-documentation-that-cannot-drift.md) | Guide code compiles; claims live in checks | `examples/snippets/generate.sh --check`; `check.py` |

Superseded: [0001](decisions/0001-native-protocols.md) by 0013, [0003](decisions/0003-crate-split.md) by 0012,
[0008](decisions/0008-toolchain.md) by 0014.

## Changing the design

- **A new rule** comes with a decision record and, where it can be checked, a section in `rules.toml` and its
  check in `check.py`, in the same change. A rule that cannot be checked says "Not checked" in its record and
  in the table above, and names what could check it.
- **A changed decision** gets a new record that says which one it supersedes. The old record keeps its text;
  only its status line changes, to `superseded by NNNN`.
- **A check** is trusted once it has been seen to fail: break the rule on purpose, run `check.py`, restore.
- Records state the decision and its reasons, not the state of the code. Numbers and lists that describe the
  code belong in `rules.toml`, where they are checked.

## Known debt

- 0005: bare `UTF8_String (...)` conversions that predate the rule are counted per file in `rules.toml`
  (`[text_conversions.known_unexplained]`) and may only fall. Each needs its reason checked and written;
  session values read from a `Session_Table` are one that is not sound today.
