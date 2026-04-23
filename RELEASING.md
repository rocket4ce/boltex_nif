# Release runbook (maintainers)

End-to-end: bump version → tag → CI builds precompiled binaries → publish to
Hex. Consumers never run a Mix task; `mix deps.get` is enough.

## 1. Prepare the version

1. Bump `@version` in **both** `mix.exs` and `lib/boltex_nif/native.ex`.
2. Move the entries from `## [Unreleased]` in `CHANGELOG.md` into a new
   `## [X.Y.Z] - YYYY-MM-DD` section and update the compare links at the
   bottom.
3. Regenerate / verify tests green:
   ```sh
   docker compose up -d
   NEO4J_URI=bolt://localhost:7687 \
     NEO4J_USER=neo4j NEO4J_PASSWORD=boltex_nif_pass \
     mix test --include live
   ```
4. Commit: `chore(release): prepare vX.Y.Z`.

## 2. Tag + push

```sh
git tag vX.Y.Z
git push origin main --tags
```

The `Build precompiled NIFs` workflow (`.github/workflows/release.yml`)
builds the 7 targets × 2 NIF versions (14 artifacts) and attaches them
to a **draft** GitHub Release for `vX.Y.Z`. Go to the Releases page and
flip the draft to published when all jobs succeeded.

## 3. Download checksums locally

With the release published, generate the checksum file that pins the
SHA-256 of every precompiled artifact:

```sh
mix deps.get
mix rustler_precompiled.download BoltexNif.Native --all --ignore-unavailable --print
```

This creates `checksum-Elixir.BoltexNif.Native.exs` at the repo root. Commit it:

```sh
git add checksum-Elixir.BoltexNif.Native.exs
git commit -m "chore(release): checksum for vX.Y.Z"
git push
```

## 4. Publish to Hex

```sh
mix hex.build --unpack   # sanity-check the tarball contents
mix hex.publish          # actually publish + docs
```

`hex.publish` asks for confirmation; it will show the file list (should
include `lib/`, `native/boltex_nif/` minus `target/`, the checksum file,
`README.md`, `LICENSE`, `CHANGELOG.md`).

## 5. Smoke-test a clean install

On a machine **without Rust toolchain installed** (or in a container):

```sh
mix new consumer_probe
cd consumer_probe
# add {:boltex_nif, "~> X.Y"} to mix.exs
mix deps.get        # should fetch a precompiled binary, not build
mix compile
```

If Rust is accidentally required, the install fails with a message from
`rustler_precompiled`. That means the checksum file or the release
artifacts are off — fix and republish (bump to X.Y.Z+1).

## 6. Post-release

- [ ] Re-open `## [Unreleased]` section in `CHANGELOG.md` for the next
      development cycle.
- [ ] Announce on Elixir forum / whatever channel.
- [ ] File any follow-ups from the release (bug reports, target requests)
      as GitHub issues tagged `released`.

## Version / target mismatch notes

- `base_url` in `lib/boltex_nif/native.ex` must match the GitHub release
  created by the workflow (`v<version>`). If you change the repo slug,
  update both.
- Adding or removing a target: update `targets:` in `native.ex`, the
  `matrix.job` list in `.github/workflows/release.yml`, and the `expected=`
  count in the `verify_matrix` job.
- NIF version support: Elixir OTP 24+ ships NIF 2.16; OTP 26+ ships 2.17.
  Keep both in `nif_versions:` to support users on older OTPs.
