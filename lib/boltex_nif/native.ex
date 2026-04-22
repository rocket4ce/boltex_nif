defmodule BoltexNif.Native do
  @moduledoc false
  # Low-level NIF interface. Do not use directly; prefer `BoltexNif`.

  use Rustler,
    otp_app: :boltex_nif,
    crate: "boltex_nif"

  # ---- graph ----
  def connect(_config), do: :erlang.nif_error(:nif_not_loaded)

  # ---- auto-commit queries ----
  def run(_graph, _cypher, _params), do: :erlang.nif_error(:nif_not_loaded)
  def run_with_summary(_graph, _cypher, _params), do: :erlang.nif_error(:nif_not_loaded)
  def execute(_graph, _cypher, _params), do: :erlang.nif_error(:nif_not_loaded)

  # ---- transactions ----
  def begin_transaction(_graph), do: :erlang.nif_error(:nif_not_loaded)
  def txn_run(_txn, _cypher, _params), do: :erlang.nif_error(:nif_not_loaded)
  def txn_execute(_txn, _cypher, _params), do: :erlang.nif_error(:nif_not_loaded)
  def commit(_txn), do: :erlang.nif_error(:nif_not_loaded)
  def rollback(_txn), do: :erlang.nif_error(:nif_not_loaded)

  # ---- streaming ----
  def stream_start(_graph, _cypher, _params), do: :erlang.nif_error(:nif_not_loaded)
  def stream_next(_stream), do: :erlang.nif_error(:nif_not_loaded)
  def stream_close(_stream), do: :erlang.nif_error(:nif_not_loaded)
end
