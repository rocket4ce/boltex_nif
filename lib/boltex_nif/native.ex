defmodule BoltexNif.Native do
  @moduledoc false
  # Low-level NIF interface. Do not use directly; prefer `BoltexNif`.

  # Keep `@version` in sync with `version:` in `mix.exs` — it's referenced by
  # `base_url` (which points at the matching GitHub release).
  @version "0.1.1"

  # `rustler_precompiled` generates the checksum file named after the module
  # (`checksum-Elixir.BoltexNif.Native.exs`) at the repo root. Anchor the
  # lookup with `__DIR__` (this file lives at `lib/boltex_nif/native.ex`) so
  # we resolve the repo root regardless of the current working directory —
  # `File.cwd!()` is not reliable here because consumers compile the dep
  # from their own project root. When the checksum file is absent we're
  # almost certainly running inside the library repo itself (pre-release or
  # contributor build) so compile the NIF from source rather than demanding
  # a published artifact. Consumers installing from Hex always get the
  # checksum file as part of the package.
  checksum_path =
    Path.join(__DIR__, "../../checksum-Elixir.BoltexNif.Native.exs")

  use RustlerPrecompiled,
    otp_app: :boltex_nif,
    crate: "boltex_nif",
    version: @version,
    base_url: "https://github.com/rocket4ce/boltex_nif/releases/download/v#{@version}",
    force_build:
      System.get_env("FORCE_BOLTEX_BUILD") in ["1", "true"] or
        not File.exists?(checksum_path),
    nif_versions: ["2.16", "2.17"],
    # musl variants are not shipped for v0.1.0 (build-from-source path is
    # available via FORCE_BOLTEX_BUILD=1 on Alpine / scratch containers).
    targets: [
      "aarch64-apple-darwin",
      "x86_64-apple-darwin",
      "aarch64-unknown-linux-gnu",
      "x86_64-unknown-linux-gnu",
      "x86_64-pc-windows-msvc"
    ]

  # ---- NIF stubs (replaced when the shared library is loaded) ---------------

  # graph
  def connect(_config), do: :erlang.nif_error(:nif_not_loaded)

  # auto-commit queries
  def run(_graph, _cypher, _params), do: :erlang.nif_error(:nif_not_loaded)
  def run_with_summary(_graph, _cypher, _params), do: :erlang.nif_error(:nif_not_loaded)
  def execute(_graph, _cypher, _params), do: :erlang.nif_error(:nif_not_loaded)

  # transactions
  def begin_transaction(_graph), do: :erlang.nif_error(:nif_not_loaded)
  def txn_run(_txn, _cypher, _params), do: :erlang.nif_error(:nif_not_loaded)
  def txn_execute(_txn, _cypher, _params), do: :erlang.nif_error(:nif_not_loaded)
  def commit(_txn), do: :erlang.nif_error(:nif_not_loaded)
  def rollback(_txn), do: :erlang.nif_error(:nif_not_loaded)

  # streaming
  def stream_start(_graph, _cypher, _params), do: :erlang.nif_error(:nif_not_loaded)
  def stream_next(_stream), do: :erlang.nif_error(:nif_not_loaded)
  def stream_close(_stream), do: :erlang.nif_error(:nif_not_loaded)
end
