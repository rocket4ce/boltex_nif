# BoltexNif

Elixir driver for [Neo4j](https://neo4j.com), implemented as a
[Rustler](https://github.com/rusterlium/rustler)-powered NIF around the
official Rust driver [`neo4rs`](https://github.com/neo4j-labs/neo4rs).

- Full **Bolt v5** protocol (via `neo4rs`'s `unstable-v1` feature bundle).
- **No Rust toolchain required** — precompiled NIFs ship for macOS, Linux
  (glibc), and Windows via
  [`rustler_precompiled`](https://hex.pm/packages/rustler_precompiled).
- **Async on the inside, sync on the outside**: every NIF call returns a
  `ref` immediately and the work runs on a shared Tokio runtime; the Elixir
  API you see is plain synchronous — `{:ok, ...}` / `{:error, ...}` with
  proper timeouts.
- **First-class types**: nodes, relationships, paths, points, temporals,
  durations, bytes, nested maps/lists — all marshalled to idiomatic Elixir
  structs.
- **Production essentials**: connection pool, explicit transactions, lazy
  row streaming, result summary (counters + notifications + bookmarks),
  TLS, user impersonation, and structured `Neo4jError` with retryable
  classification.

## Table of contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Connecting](#connecting)
- [Running queries](#running-queries)
- [Transactions](#transactions)
- [Streaming](#streaming)
- [Type mapping](#type-mapping)
- [Error handling](#error-handling)
- [Concurrency & the connection pool](#concurrency--the-connection-pool)
- [Using it from Phoenix](#using-it-from-phoenix)
- [Local development](#local-development)
- [Testing](#testing)
- [Roadmap](#roadmap)
- [Releasing new versions (maintainers)](#releasing-new-versions-maintainers)
- [License](#license)

## Installation

Add to `mix.exs` and run `mix deps.get` — that's it:

```elixir
def deps do
  [
    {:boltex_nif, "~> 0.1"}
  ]
end
```

**No Rust toolchain required.** `boltex_nif` ships precompiled NIFs for:

| OS            | Architectures                           |
|---------------|-----------------------------------------|
| macOS         | aarch64 (Apple silicon), x86_64 (Intel) |
| Linux (glibc) | x86_64, aarch64                         |
| Windows       | x86_64 (MSVC)                           |

For unsupported targets (musl/Alpine, 32-bit ARM, RISC-V, …) or to force a
local build, set `FORCE_BOLTEX_BUILD=1` and add `{:rustler, "~> 0.37"}` to
your own deps:

```sh
FORCE_BOLTEX_BUILD=1 mix deps.compile boltex_nif
```

Building from source needs Rust ≥ 1.81.

### Runtime requirements

- Elixir 1.19 / OTP 28 (the regression-tested matrix). NIF 2.16 binaries
  are published too, so older Elixir/OTP combos with NIF ≥ 2.16 should
  also work, they just aren't part of the test matrix.
- A reachable Neo4j 5.x instance (Community or Enterprise). The repo ships
  `docker-compose.yml` (local dev) and `docker-compose.production.yml`
  (Coolify-ready) — see [Local development](#local-development).

## Quick start

```elixir
{:ok, graph} =
  BoltexNif.connect(
    uri: "bolt://localhost:7687",
    user: "neo4j",
    password: "boltex_nif_pass"
  )

:ok = BoltexNif.run(graph, "MERGE (:Greeter {name:$n})", %{"n" => "Ada"})

{:ok, rows} =
  BoltexNif.execute(graph, "MATCH (g:Greeter) RETURN g.name AS name")

Enum.map(rows, & &1["name"])
#=> ["Ada"]
```

## Connecting

`BoltexNif.connect/1` takes a keyword list or a map:

```elixir
{:ok, graph} =
  BoltexNif.connect(
    uri: "bolt://localhost:7687",     # required — bolt:// or neo4j:// (routing)
    user: "neo4j",                    # required
    password: "secret",               # required
    db: "neo4j",                      # optional — default database
    fetch_size: 500,                  # optional — rows per pull (driver default 200)
    max_connections: 16,              # optional — pool size (driver default 16)
    impersonate_user: "alice",        # optional — Bolt v5 impersonation
    tls: :skip_validation,            # optional — see below
    timeout: 15_000                   # optional — connect handshake timeout (ms)
  )
```

### TLS

```elixir
tls: nil                                  # default — honors scheme (neo4j+s://, bolt+ssc://)
tls: {:ca, "/etc/ssl/neo4j-ca.pem"}       # validate server cert against the CA
tls: {:mutual, ca: "/etc/ssl/ca.pem", cert: "/etc/ssl/client.pem", key: "/etc/ssl/client.key"}
tls: :skip_validation                     # accept anything — DO NOT use in prod
```

The returned `graph` is an opaque `reference()` you pass to every query
function. It can be safely shared across processes — internal connection
pooling is handled by the Rust layer.

## Running queries

Three flavors, increasing in what they return:

### `run/4` — fire-and-forget

```elixir
:ok = BoltexNif.run(graph, "CREATE (:Foo {i:$i})", %{"i" => 1})
# or with an options keyword:
:ok = BoltexNif.run(graph, "CREATE (:Foo)", nil, timeout: 30_000)
```

### `run_with_summary/4` — write stats without rows

```elixir
{:ok, %BoltexNif.Summary{stats: stats, query_type: type}} =
  BoltexNif.run_with_summary(graph, "CREATE (:Foo {i:1}), (:Foo {i:2})")

stats.nodes_created       #=> 2
stats.properties_set      #=> 2
type                      #=> "write" (or "read" / "read_write" / "schema_write")
```

Full fields on `%BoltexNif.Summary{}`:

- `bookmark` — `String.t() | nil` — Bolt v5 bookmark for `start_txn_as`.
- `available_after_ms`, `consumed_after_ms` — server-side timings.
- `query_type` — `"read" | "write" | "read_write" | "schema_write"`.
- `db` — database the query ran against.
- `stats` — `%BoltexNif.Summary.Counters{}` with `nodes_created`,
  `relationships_created`, `properties_set`, `labels_added`,
  `indexes_added`, `constraints_added`, their `*_deleted`/`*_removed`
  counterparts, and `system_updates`.
- `notifications` — `[%BoltexNif.Notification{}]` (code, title, severity,
  category, source `InputPosition`).

### `execute/4` — collect all rows

```elixir
{:ok, rows} =
  BoltexNif.execute(
    graph,
    "MATCH (p:Person {age: $age}) RETURN p.name AS name, p.age AS age ORDER BY name",
    %{"age" => 30},
    timeout: 60_000
  )

rows
#=> [%{"name" => "Ada", "age" => 30}, %{"name" => "Grace", "age" => 30}]
```

Rows are plain maps keyed by the `AS` alias you declare in the Cypher.

## Transactions

### Imperative — full control over commit/rollback

```elixir
{:ok, txn} = BoltexNif.begin_transaction(graph)

{:ok, _summary} = BoltexNif.txn_run(txn, "CREATE (:T {x:1})")
{:ok, rows}    = BoltexNif.txn_execute(txn, "MATCH (t:T) RETURN t")

# Either:
:ok                        = BoltexNif.rollback(txn)
# or (Bolt v5 returns the bookmark, otherwise just :ok):
{:ok, bookmark_or_nil}     = BoltexNif.commit(txn)
```

### Declarative — `transaction/3`

Commits on `{:ok, value}`, rolls back on `{:error, _}`, re-raises on
exceptions (rollback first):

```elixir
{:ok, count} =
  BoltexNif.transaction(graph, fn txn ->
    {:ok, _} = BoltexNif.txn_run(txn, "CREATE (:T {x:1})")
    {:ok, rows} = BoltexNif.txn_execute(txn, "MATCH (t:T) RETURN count(t) AS c")
    {:ok, rows |> hd() |> Map.get("c")}
  end)
```

## Streaming

For result sets bigger than memory, stream row by row:

```elixir
{:ok, stream} =
  BoltexNif.stream_start(graph, "MATCH (n) RETURN n LIMIT 100_000")

Stream.repeatedly(fn -> BoltexNif.stream_next(stream) end)
|> Enum.take_while(&(&1 != :done))
|> Enum.each(fn {:ok, row} -> process(row) end)
```

- `{:ok, row}` — one row returned.
- `:done` — stream exhausted (connection is returned to the pool).
- `{:error, :closed}` — `stream_next` called after `:done` or `stream_close/1`.
- `BoltexNif.stream_close(stream)` — drop early without draining; `:ok`
  even if already closed.

## Type mapping

### Parameters (Elixir → Bolt)

| Elixir value                                                   | Becomes (Bolt)   |
|----------------------------------------------------------------|------------------|
| `nil`                                                          | `Null`           |
| `true` / `false`                                               | `Boolean`        |
| `integer()`                                                    | `Integer` (i64)  |
| `float()`                                                      | `Float` (f64)    |
| `binary()` (UTF-8)                                             | `String`         |
| `{:bytes, binary()}`                                           | `Bytes`          |
| `list()`                                                       | `List`           |
| `map()` — keys **must be** strings or atoms                    | `Map`            |
| `%Date{}`                                                      | `Date`           |
| `%Time{}`                                                      | `LocalTime`      |
| `%NaiveDateTime{}`                                             | `LocalDateTime`  |
| `%DateTime{}`                                                  | `DateTime`       |
| `%BoltexNif.Time{time: %Time{}, offset_seconds}`               | `Time`           |
| `%BoltexNif.DateTime{naive: %NaiveDateTime{}, offset_seconds}` | `DateTime`       |
| `%BoltexNif.DateTimeZoneId{naive, tz_id}`                      | `DateTimeZoneId` |
| `%BoltexNif.Duration{months, days, seconds, nanoseconds}`      | `Duration`       |
| `%BoltexNif.Point{srid, x, y, z \\ nil}`                       | `Point2D`/`3D`   |
| `%BoltexNif.Node{id, labels, properties}`                      | `Node`           |
| `%BoltexNif.Relationship{...}`                                 | `Relationship`   |
| `%BoltexNif.UnboundRelationship{id, type, properties}`         | `UnboundRel`     |

### Results (Bolt → Elixir)

Symmetric to the param table. Highlights:

- `Bolt String` → UTF-8 `binary()`.
- `Bolt Bytes` → `{:bytes, binary()}`.
- `Bolt Date`/`LocalTime`/`LocalDateTime` → stdlib `%Date{}` / `%Time{}` /
  `%NaiveDateTime{}`.
- `Bolt DateTime` (FixedOffset) → `%BoltexNif.DateTime{}` (keeps offset
  without needing a TZ database).
- `Bolt DateTimeZoneId` → `%BoltexNif.DateTimeZoneId{}`.
- `Bolt Time` (with offset) → `%BoltexNif.Time{}`.
- `Bolt Duration` → `%BoltexNif.Duration{}` (Bolt keeps months/days/
  seconds/nanos separately; we never collapse them).
- `Bolt Point2D` → `%BoltexNif.Point{z: nil}`; `Point3D` → `z: float()`.
- `Bolt Node` → `%BoltexNif.Node{id, labels, properties}`.
- `Bolt Relationship` → `%BoltexNif.Relationship{id, start_node_id,
  end_node_id, type, properties}`.
- `Bolt Path` → `%BoltexNif.Path{nodes, relationships, indices}` where
  `relationships` is a list of `%BoltexNif.UnboundRelationship{}`.

## Error handling

Every `{:error, _}` response is one of:

```elixir
{:error, {:neo4j, %BoltexNif.Neo4jError{code: code, message: msg, kind: kind}}}
{:error, {:invalid_config, msg}}
{:error, {:io, msg}}
{:error, {:deserialization, msg}}
{:error, {:unexpected_type, msg}}
{:error, {:unexpected, msg}}
{:error, {:argument, msg}}
{:error, :timeout}          # NIF didn't answer within the caller's timeout
```

`kind` on a Neo4j error classifies the failure for retry decisions. One of:

`:authentication`, `:authorization_expired`, `:token_expired`,
`:other_security`, `:session_expired`, `:fatal_discovery`,
`:transaction_terminated`, `:protocol_violation`, `:client_other`,
`:client_unknown`, `:transient`, `:database`, `:unknown`.

```elixir
case BoltexNif.execute(graph, cypher, params) do
  {:ok, rows} -> rows
  {:error, {:neo4j, err}} ->
    if BoltexNif.Neo4jError.retryable?(err), do: retry(), else: raise("boom: #{err.message}")
  {:error, :timeout} -> retry()
end
```

## Concurrency & the connection pool

- The underlying `neo4rs` pool is bounded by `:max_connections` (default
  16). All BoltexNif functions are **safe to call concurrently** from any
  number of processes — they queue up on the Rust-side pool transparently.
- Each call returns a fresh `ref` and waits on a single Erlang message
  (`{ref, result}`), so it obeys `:timeout` cleanly even while queued.
- A request that times out on the Elixir side only stops **waiting** for
  the result; the Rust task finishes anyway and its reply is dropped. Keep
  `:timeout` generous when you know you might be behind a deep queue.
- Measured throughput against a remote Coolify Neo4j (≈ 430 ms RTT): ~9
  q/s per connection, 50× pool over-subscription handled without losses.
  Against a local `docker compose up -d` Neo4j: order of magnitude higher.

See `phoenix_neo4j/test/phoenix_neo4j/neo4j_stress_test.exs` for the
`:stress` suite (parallel reads/writes, transaction interleaving,
streaming concurrency, pool saturation).

## Using it from Phoenix

The repo includes **`phoenix_neo4j/`** — a minimal Phoenix 1.8 app that
wires `boltex_nif` into a supervision tree, exposes the pool, and serves a
demo `/neo4j` page (list/create/delete `:Greeter` nodes).

Core pattern in `phoenix_neo4j/lib/phoenix_neo4j/neo4j.ex`:

```elixir
defmodule MyApp.Neo4j do
  use GenServer
  @key {__MODULE__, :graph}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def graph, do: :persistent_term.get(@key)

  def run(cypher, params \\ nil, opts \\ []),
    do: BoltexNif.run(graph(), cypher, params, opts)

  def execute(cypher, params \\ nil, opts \\ []),
    do: BoltexNif.execute(graph(), cypher, params, opts)

  @impl true
  def init(opts) do
    {:ok, graph} = BoltexNif.connect(opts)
    :persistent_term.put(@key, graph)
    {:ok, %{graph: graph}}
  end
end
```

Add to your Application:

```elixir
children = [
  # …,
  {MyApp.Neo4j, uri: System.fetch_env!("NEO4J_URI"),
                user: System.fetch_env!("NEO4J_USER"),
                password: System.fetch_env!("NEO4J_PASSWORD"),
                max_connections: 16}
]
```

Callers just use `MyApp.Neo4j.execute/2` — no GenServer bottleneck, pool
is handled in Rust.

To run the demo:

```sh
docker compose up -d
cd phoenix_neo4j
mix deps.get
NEO4J_URI=bolt://localhost:7687 NEO4J_USER=neo4j NEO4J_PASSWORD=boltex_nif_pass \
  mix phx.server
# visit http://localhost:4000/neo4j
```

## Local development

Two compose files ship with the repo:

### `docker-compose.yml` — local dev

Neo4j 5.26 Community, bound to `localhost:7687`:

```sh
docker compose up -d      # boot
docker compose down -v    # tear down and drop volumes
```

Default creds: `neo4j` / `boltex_nif_pass`.

### `docker-compose.production.yml` — Coolify-ready

Production-oriented: APOC auto-install, query logging, healthcheck via
`cypher-shell`, memory & ulimit tuning, opt-in backup sidecar using APOC
export. Drop into Coolify's "Docker Compose" resource and pass the env
vars from `.env.production.example`.

Automatic `SERVICE_FQDN_NEO4J` substitution means you only need to set
`CFG_NEO4J_PASSWORD` — the rest has sensible defaults. See comments at
the top of the file for the TLS-for-Bolt block and the `:port` gotchas
around Cloudflare (Bolt TCP needs DNS-only, not proxied).

## Testing

The test suite is live-by-default — it will refuse to run the DB-touching
tests unless `NEO4J_URI` is set. Two tag tiers:

- `:live` — touches Neo4j. Excluded when `NEO4J_URI` isn't set.
- `:stress` — opt-in, long-running concurrency tests. Always excluded by
  default.

```sh
# Library tests (14 cases):
NEO4J_URI=bolt://localhost:7687 NEO4J_USER=neo4j NEO4J_PASSWORD=boltex_nif_pass \
  mix test --include live

# Phoenix demo tests (48 cases):
cd phoenix_neo4j
NEO4J_URI=bolt://localhost:7687 NEO4J_USER=neo4j NEO4J_PASSWORD=boltex_nif_pass \
  mix test --include live

# Full concurrency/stress suite (add --only stress to isolate):
cd phoenix_neo4j
NEO4J_URI=bolt://localhost:7687 NEO4J_USER=neo4j NEO4J_PASSWORD=boltex_nif_pass \
  STRESS_SCALE=1.0 \
  mix test --include live --include stress
```

### One-shot smoke

`scripts/smoke.sh` runs an end-to-end check: Phoenix HTTP endpoints (if a
server is up at `$PHX_URL`), the BoltexNif type / transaction / streaming
probes in `scripts/smoke.exs`, and the full `mix test --include live`.

```sh
# Requires Neo4j reachable at $NEO4J_URI (defaults baked in for Coolify).
./scripts/smoke.sh
# or isolate phases:
SKIP_PHX=1 ./scripts/smoke.sh        # only library
SKIP_MIX_TEST=1 ./scripts/smoke.sh   # library checks + phoenix HTTP
```

## Roadmap

- **Phase 1** (done): scaffolding, primitives + graph/temporal/spatial
  types, auto-commit `run`/`execute`.
- **Phase 2** (done): transactions, streaming, `ResultSummary`.
- **Phase 3** (done): Bolt v5 bookmarks, TLS, impersonation, structured
  Neo4j errors.
- **Phase 4** (done): precompiled NIFs via `rustler_precompiled`, Hex
  metadata, GitHub Actions release pipeline.
- **Future**:
  - `element_id` on Nodes/Relationships (requires decoding via the Bolt v5
    serde path, not the classic `types/*` tree).
  - Optional `neo4rs` features: `json` (transparent `serde_json::Value`),
    `uuid` (`Ecto.UUID` ↔ `String`).
  - Per-stream `fetch_size` override, streaming within a transaction.
  - `:telemetry` hooks (query start/stop, pool checkout, tx commit).
  - musl (Alpine) precompiled targets once a working `Cross.toml` is in
    place.

## Releasing new versions (maintainers)

`.github/workflows/release.yml` runs only on tag pushes (`v*`). It builds
a matrix of 5 targets × 2 NIF versions (10 artifacts) and uploads them to
a draft GitHub Release. After publishing the draft, run:

```sh
mix rustler_precompiled.download BoltexNif.Native --all --ignore-unavailable --print
git add checksum-boltex_nif-X.Y.Z.exs
git commit -m "chore(release): checksum for vX.Y.Z"
git push
mix hex.publish
```

Full step-by-step in [`RELEASING.md`](RELEASING.md).

## License

MIT — see [`LICENSE`](LICENSE).
