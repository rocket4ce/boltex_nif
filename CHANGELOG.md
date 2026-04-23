# Changelog

All notable changes to this project are documented in this file. The format
is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-04-22

### Added
- First public release.
- Rustler-based NIF wrapping [`neo4rs`](https://github.com/neo4j-labs/neo4rs)
  `0.9.0-rc.9` with the `unstable-v1` feature bundle (Bolt v5 protocol,
  result summaries, packstream serde).
- Precompiled binaries shipped via `rustler_precompiled` — no Rust toolchain
  required to install on macOS (ARM/Intel), Linux (glibc/musl, x86_64/ARM64)
  and Windows (MSVC x86_64). `FORCE_BOLTEX_BUILD=1` opts into building from
  source.
- Async NIF pattern built on a global Tokio runtime: every call returns a
  fresh `ref` synchronously and the driver sends `{ref, result}` back through
  `OwnedEnv::send_and_clear`.
- Auto-commit queries: `BoltexNif.connect/1`, `run/4`, `execute/4`,
  `run_with_summary/4`.
- Explicit transactions: `begin_transaction/2`, `txn_run/4`, `txn_execute/4`,
  `commit/2`, `rollback/2`, plus the `transaction/3` helper (commit on
  `{:ok, _}`, rollback on `{:error, _}`, rollback + re-raise on exception).
- Lazy row streaming: `stream_start/4`, `stream_next/2`, `stream_close/2`.
- Full Bolt type marshalling to idiomatic Elixir:
  - Primitives and collections.
  - Graph types: `%BoltexNif.Node{}`, `%BoltexNif.Relationship{}`,
    `%BoltexNif.UnboundRelationship{}`, `%BoltexNif.Path{}`.
  - Spatial: `%BoltexNif.Point{}` (2D/3D).
  - Temporal: `%Date{}`, `%Time{}`, `%NaiveDateTime{}`, plus
    `%BoltexNif.Time{}`, `%BoltexNif.DateTime{}`,
    `%BoltexNif.DateTimeZoneId{}`, `%BoltexNif.Duration{}`.
- `%BoltexNif.Summary{}` + `Counters` + `Notification` for operational
  metadata (available/consumed-after ms, query type, counters, notifications
  with source position).
- Structured Neo4j errors as `%BoltexNif.Neo4jError{code, message, kind}`
  with 13 classified kinds and `Neo4jError.retryable?/1`.
- TLS configuration (CA, mutual, skip-validation), user impersonation,
  bookmarks on commit.

### Unreleased / future
- `element_id` on Nodes/Relationships (requires decoding via the Bolt v5
  serde path, not the classic `types/*` tree we currently use).
- Feature flags for `json` and `uuid` in `neo4rs`.
- Richer streaming (per-stream `fetch_size` override, streaming within a
  transaction).

[Unreleased]: https://github.com/rocket4ce/boltex_nif/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/rocket4ce/boltex_nif/releases/tag/v0.1.0
