# BoltexNif

Elixir NIF bindings around the [`neo4rs`](https://github.com/neo4j-labs/neo4rs)
Rust driver for Neo4j, via [Rustler](https://github.com/rusterlium/rustler).

All operations run on a global Tokio runtime inside the NIF. Each call returns
a fresh `ref` synchronously; the NIF sends `{ref, result}` back to the calling
process when the work completes. The public Elixir API is plain synchronous —
you never have to manage messages yourself.

Enables `neo4rs`'s `unstable-v1` feature set (Bolt v5 protocol, result summary,
packstream serde). Targets `neo4rs 0.9.0-rc.9`, Rustler `~> 0.37`, Elixir 1.19.

## Installation

Add to your `mix.exs` and run `mix deps.get` — that's it:

```elixir
def deps do
  [
    {:boltex_nif, "~> 0.1"}
  ]
end
```

**No Rust toolchain required.** `boltex_nif` ships precompiled NIFs
(via [`rustler_precompiled`](https://hex.pm/packages/rustler_precompiled))
for the following targets:

| OS            | Architectures                                      |
|---------------|----------------------------------------------------|
| macOS         | aarch64 (Apple silicon), x86_64 (Intel)            |
| Linux (glibc) | x86_64, aarch64                                    |
| Linux (musl)  | x86_64, aarch64 (Alpine, scratch-based containers) |
| Windows       | x86_64 (MSVC)                                      |

For unsupported targets (e.g. 32-bit ARM, RISC-V), or to force a local
build:

```sh
FORCE_BOLTEX_BUILD=1 mix deps.compile boltex_nif
```

Building from source needs Rust ≥ 1.81. Add `{:rustler, "~> 0.37"}` to
your own deps when you force-build — it's marked `optional: true` here.

## Requirements (runtime)

- Elixir 1.19 / OTP 28 (current test matrix; older Elixir/OTP combos with
  NIF 2.16 support are likely to work but aren't regression-tested).
- A reachable Neo4j instance. A ready-to-use `docker-compose.yml` ships a
  Neo4j 5 community container:

```sh
docker compose up -d        # boots Neo4j on bolt://localhost:7687
docker compose down -v      # tear down and drop volumes
```

Default test credentials: `neo4j` / `boltex_nif_pass`.

## Connecting

```elixir
{:ok, graph} =
  BoltexNif.connect(
    uri: "bolt://localhost:7687",
    user: "neo4j",
    password: "boltex_nif_pass",
    db: "neo4j",               # optional
    fetch_size: 500,           # optional
    max_connections: 16,       # optional
    impersonate_user: "alice", # Bolt v5
    tls: :skip_validation      # :ca | :mutual | :skip_validation
  )
```

TLS shapes:

```elixir
tls: {:ca, "/etc/ssl/neo4j-ca.pem"}
tls: {:mutual, cert: "/etc/ssl/client.pem", key: "/etc/ssl/client.key"}
tls: :skip_validation
```

## Queries

```elixir
:ok = BoltexNif.run(graph, "MATCH (n:Person) DETACH DELETE n")

{:ok, rows} =
  BoltexNif.execute(
    graph,
    "MATCH (p:Person {name: $name}) RETURN p",
    %{"name" => "Alice"}
  )

{:ok, %BoltexNif.Summary{stats: s}} =
  BoltexNif.run_with_summary(graph, "CREATE (:Person {name: 'Bob'})")

s.nodes_created   #=> 1
```

## Transactions

```elixir
{:ok, value} =
  BoltexNif.transaction(graph, fn txn ->
    {:ok, _} = BoltexNif.txn_run(txn, "CREATE (:Person {name: 'Carol'})")
    {:ok, rows} = BoltexNif.txn_execute(txn, "MATCH (p:Person) RETURN p")
    {:ok, length(rows)}
  end)
```

`BoltexNif.transaction/3` commits on `{:ok, _}`, rolls back on `{:error, _}`,
and re-raises on exceptions. You can also drive a transaction manually:

```elixir
{:ok, txn} = BoltexNif.begin_transaction(graph)
{:ok, _summary} = BoltexNif.txn_run(txn, "CREATE (:T {i: 1})")
:ok = BoltexNif.rollback(txn)
```

## Streaming

```elixir
{:ok, stream} = BoltexNif.stream_start(graph, "MATCH (n) RETURN n LIMIT 10000")

loop = fn loop, acc ->
  case BoltexNif.stream_next(stream) do
    {:ok, row} -> loop.(loop, [row | acc])
    :done -> Enum.reverse(acc)
  end
end

rows = loop.(loop, [])
```

Use `BoltexNif.stream_close(stream)` to drop a stream early without draining.

## Types

| Bolt                     | Elixir                                                  |
|--------------------------|---------------------------------------------------------|
| Null                     | `nil`                                                   |
| Boolean / Integer / Float| `boolean()` / `integer()` / `float()`                   |
| String                   | UTF-8 `binary()`                                        |
| Bytes                    | `{:bytes, binary()}`                                    |
| List / Map               | `list()` / `map()` (keys coerced to strings)            |
| Node                     | `%BoltexNif.Node{}`                                     |
| Relationship             | `%BoltexNif.Relationship{}`                             |
| UnboundRelationship      | `%BoltexNif.UnboundRelationship{}` (paths)              |
| Path                     | `%BoltexNif.Path{}`                                     |
| Point2D / Point3D        | `%BoltexNif.Point{}` (`z` is `nil` for 2D)              |
| Date / LocalTime / LocalDateTime | `%Date{}` / `%Time{}` / `%NaiveDateTime{}`      |
| Time (with offset)       | `%BoltexNif.Time{time, offset_seconds}`                 |
| DateTime (FixedOffset)   | `%BoltexNif.DateTime{naive, offset_seconds}`            |
| DateTimeZoneId           | `%BoltexNif.DateTimeZoneId{naive, tz_id}`               |
| Duration                 | `%BoltexNif.Duration{months, days, seconds, nanoseconds}` |

## Errors

All error tuples share the shape `{:error, {kind, payload}}`. Possible kinds:

- `:invalid_config`, `:io`, `:deserialization`,
  `:unexpected_type`, `:unexpected`, `:argument` — `payload` is a human
  string.
- `:neo4j` — `payload` is a `%BoltexNif.Neo4jError{code, message, kind}`
  with `kind` one of `:authentication`, `:authorization_expired`,
  `:token_expired`, `:other_security`, `:session_expired`,
  `:fatal_discovery`, `:transaction_terminated`, `:protocol_violation`,
  `:client_other`, `:client_unknown`, `:transient`, `:database`,
  `:unknown`.
- `:timeout` — `{:error, :timeout}` when the NIF didn't answer within the
  `:timeout` option (default 15 s).

`BoltexNif.Neo4jError.retryable?/1` returns `true` for the categories
`neo4rs` treats as retryable (transient, session-expired,
authorization-expired).

## Running the test suite

The full suite uses live Neo4j. Set the connection env vars and include the
`:live` tag:

```sh
docker compose up -d
NEO4J_URI=bolt://localhost:7687 \
  NEO4J_USER=neo4j \
  NEO4J_PASSWORD=boltex_nif_pass \
  mix test --include live
```

Without `NEO4J_URI`, the suite skips the `:live` tag and runs zero tests.

## Roadmap

- Phase 1 (done): scaffolding, primitives + graph/temporal/spatial types, auto-commit `run`/`execute`.
- Phase 2 (done): transactions, streaming, `ResultSummary`.
- Phase 3 (done): Bolt v5 bookmarks, TLS, impersonation, structured Neo4j errors.
- Future: `element_id` support (needs the `bolt/structs/*` tree, not the
  classic `types/*` path we marshal today), `json`/`uuid` feature wiring, richer
  streaming (per-stream fetch_size override).

## Releasing new versions (maintainers)

See [`RELEASING.md`](RELEASING.md) for the cut-a-release checklist (bump
version → tag → CI builds precompiled binaries → download checksums →
`mix hex.publish`).
