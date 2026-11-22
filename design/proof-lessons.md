# Proof lessons learned

Notes kept while reviewing and tuning the SPARK proofs. Add a line each time a proof problem is solved.
This is not a decision record; it records what worked, so the next proof change starts from it.

## Toolchain and configuration

- Installed gnatprove is FSF 16.1.0 (cvc5 1.3.2, z3 4.15.4, Alt-Ergo 2.6.1). It accepts `--prover`,
  `--timeout`, `--steps`, `--level`, `--checks-as-errors` and `--function-sandboxing`. The newer SPARK
  User's Guide 28.0w also documents `--proof-manifest-dir` and `--sarif-base-uri`, which 16.1.0 has not.
- `--level=2` means `cvc5,z3,altergo`, 5 s, 1000 MB, counterexamples on; `--level=4` means the same
  provers, 60 s, 2000 MB, counterexamples on. An explicit `--prover` or `--timeout` overrides the level;
  explicit `--steps` also removes the default step limit. Keep `--level=4` and override timeout/provers.
- `--report=provers` prints which prover proved each VC; `--report=statistics` adds time and steps.
  This is the quickest way to see that a proof depends on a prover we are about to drop.
- Use `--limit-line=<file>:<line>` for a single failing check; it turns minutes into seconds.
- `--mode=silver` is the project target (absence of run-time errors). `--checks-as-errors=on` plus
  `--warnings=error` is what makes an unproved check fail CI.

## Provers

- At `--level=2`, Alt-Ergo proves checks in `sparrow-deflate.adb` (`Find`) that cvc5/z3 cannot prove in
  5 s. Restricting to cvc5/z3 is therefore a *proof* change, not only a configuration change.
  Those checks must be re-proved with intermediate assertions, not merely reconfigured.

## Proof-writing techniques that worked

- A check that times out after an `exit when` usually lacks bounds on the loop variable at that point.
  Put checked `pragma Assert` statements immediately after the exit: they are proved from the negated
  exit condition and give the provers explicit bounds for the rest of the iteration.
- For a modular (`Unsigned_32`) value compared with a signed index, neither cvc5 nor z3 connects the
  modular and integer views reliably. Assert the round trip explicitly
  (`Unsigned_32 (Natural (X)) = X`) and assert the conversion of the *other* operand first.
  A single large mixed modular/integer inequality times out; split it into small steps.
- The SPARK 28.0w guide recommends `Annotate => (GNATprove, No_Bitwise_Operations)` on a modular type
  when bitvector modeling makes proofs hard, but it forbids bitwise operations on that type, so it
  cannot be applied blindly to `Unsigned_32` (deflate uses shifts). Use a derived type or assertions.

## Solved problems

- **`Sparrow.Deflate.Find` chain bounds (5 timeouts).** The chain offset (`Unsigned_32`) was compared with
  string indexes, and cvc5/z3 time out on the mixed modular/integer reasoning. Fix: derive `Chain_Offset`
  from `Unsigned_32` with `Annotate => (GNATprove, No_Bitwise_Operations)` in the private part of
  `sparrow-deflate.ads`, use it for `Head_Table`, `Offset`, `Candidate` and the chain step, and add two
  checked assertions right after the `exit when`: the negated exit condition and `Best <= Input'Last -
  Position`. Adding only assertions did not work; the type annotation was needed. Removing four bridging
  assertions afterwards still proved, so keep the minimal set.
- **`Sparrow.Http.Hpack.Read_Integer` overflow timeout.** `Byte mod 128 * Scale (Step)` is nonlinear
  (mod expression times an array select). Fix: bind both factors to local constants `Fragment` and
  `Factor`, assert their individual bounds (`<= 127`, `<= 2 ** 21`), then multiply the constants.
  Asserting bounds on the original expressions was not enough.

## Process

- When changing prover settings, prove *all* crates: a prover that succeeds on small crates may still be
  needed by one check in a large one. `tests/prove.sh` stops at the first failing crate.
- Validate with `gnatprove --clean` on every crate before a full run; session files can hide a check that
  only Alt-Ergo can prove. A clean run of all 9 crates with the final flags takes about 7 minutes.

## SPARK_Mode Off: what was tried

- Boundary rule to remember: SPARK code can call SPARK_Mode => Off code if the off declarations have
  contracts (Pre/Post/Global). The proof uses the contract and never looks into the off body. If an Off
  unit is hard to remove, first check whether its spec lacks contracts — adding them may let callers
  become SPARK even while the implementation stays Off.

- `Requests.Json_Body` (spec and body Off): enabling it fails SPARK legality with `subtype constraint cannot
  depend on variable input "Nodes"` (E0007) — the `Document` discriminant is computed from the input. Using
  the maximum discriminant would allocate about a million nodes per call. Keep Off.
- `Http.Compression.Contains_Folded`: was Off for an underflowing loop bound. **Fixed**: added
  `if Part'Length > Text'Length then return False`, removed the Off, and the whole function now proves.
- `Http.Compression.Apply`: enabling it fails on `Compression.Pool` (Off, access type) and on an
  uninitialized allocator in `Apply` itself (E0019). Calling Off code is *not* by itself a blocker:
  SPARK code may call a subprogram whose body is `SPARK_Mode => Off` as long as its declaration carries
  contracts (Pre/Post/Global), which the SPARK side then trusts. Crypto works this way: the specs are
  SPARK with `Post` contracts and the OpenSSL bodies are Off. Here adding contracts to the pool would
  not fix the heap allocator in `Apply`, so keep it Off unless the pool is redesigned.
- `Json.Writers.Is_Finite` (`Number'Valid`): legal SPARK, but GNATprove warns `attribute-valid-always-true`,
  so the function would be assumed True — unsound. Keep Off, as with `Float_Image` (`Img` is imprecise).
- The remaining Off islands are C bindings (crypto bodies, POSIX/Windows bodies, libcrypto, TLS), float
  conversions and PostgreSQL `Float_Value` (documented floating-point limitations), and task/heap code
  (metrics, migrations, queries, JSON builders/iteration). Those are genuine SPARK-boundary cases.

## Review findings to carry forward

- `design/check.py` checks only the package-level `SPARK_Mode` of the units in `[proved]`. A nested
  `pragma SPARK_Mode (Off)` or a subprogram aspect inside a proved unit is not detected, even though
  decision 0004 says every check in those units is proved.
- `SECURITY.md` still says "Sparrow is before 1.0" while the release is 1.0.0.
