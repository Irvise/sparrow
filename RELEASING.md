# Releasing

How a version of the thirteen crates gets to the Alire community index. The crates are versioned and released
together.

## Once, before the first release

1. ~~Create the public repository~~: https://github.com/michael-hardeman/sparrow (`origin`), now set as
   every manifest's `website`.
2. Push, and check that CI is green on every platform. It has not run yet.
3. Turn on private vulnerability reporting (Settings, Security), as `SECURITY.md` promises.

## Each release

1. **Version.** Set `version` in every `sparrow_*/alire.toml` and in `tests/`, `tests/fuzz/` and `examples/`.
   Set the sibling dependencies (`sparrow_core = "~0.1.0-dev"` and so on) to the new version.
2. **Changelog.** Date the `Unreleased` section of `CHANGELOG.md` with the version and open a new, empty one.
   0.1.0 is the first entry: there is no history before it.
3. **Checks**, all green:
   - `tests/run.sh`, with `tests/postgres_server.sh` running
   - `tests/prove.sh`
   - `tests/fuzz/run.sh 600`
   - `tests/race.sh`
   - `cd examples && alr build`
   - `examples/snippets/generate.sh --check` (every snippet compiles, and the guides are current)
   - CI on the release commit
4. **Tag.** Commit, then tag `v<version>` and push the tag.
5. **Publish, in dependency order,** waiting for each pull request to the index to merge before the crates
   that depend on it:
   1. `sparrow_core`
   2. `sparrow_io`, `sparrow_json`, `sparrow_sqlite`, `sparrow_postgres`, `sparrow_crypto`
   3. `sparrow_templates`, `sparrow_jwt`, `sparrow_http`, `sparrow_valkey`, `sparrow_client`
   4. `sparrow_s3`, `sparrow_open_telemetry`

   For each: `cd sparrow_<name> && alr publish <repository URL> v<version>`. Alire works out the
   subdirectory, checks the manifest and opens the pull request. To check a manifest without submitting, run
   `alr publish --skip-submit` first.

## Notes

- **Pins.** The `[[pins]]` tables point siblings at `../sparrow_*` for development. Alire ignores pins in
  dependencies, so dependents resolve the published versions. If `alr publish` refuses a manifest because of
  its pins, publish from a copy with them removed.
- **Externals.** The index's `libpq` and `libsqlite3` entries have no Homebrew or Arch package
  names, so `alr` calls those dependencies missing on macOS and Arch even when the libraries are installed.
  Builds still work there. Adding the names to the index is a separate pull request.
