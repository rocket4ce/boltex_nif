defmodule BoltexNif do
  @moduledoc """
  Elixir NIF bindings for the [`neo4rs`](https://github.com/neo4j-labs/neo4rs)
  Rust driver for Neo4j.

  All public functions are synchronous at the Elixir layer. Internally the Rust
  side spawns work on a global Tokio runtime and signals completion by sending
  `{ref, result}` back to the calling process. The Elixir wrapper blocks on a
  `receive` until the response arrives or `:timeout` elapses.

  ## High-level API

    * `connect/1` — open a connection pool.
    * `run/4` / `execute/4` — auto-commit queries.
    * `run_with_summary/4` — auto-commit + `%BoltexNif.Summary{}`.
    * `begin_transaction/2` + `txn_run/4` + `txn_execute/4` + `commit/2` + `rollback/2`.
    * `stream_start/4` + `stream_next/2` + `stream_close/2` — lazy row streaming.
  """

  alias BoltexNif.Native

  @type graph :: reference()
  @type txn :: reference()
  @type stream :: reference()
  @type config :: keyword() | map()
  @type params :: map() | nil
  @type row :: %{optional(String.t()) => term()}

  @default_timeout 15_000

  # ===========================================================================
  # Connection
  # ===========================================================================

  @doc """
  Connect to a Neo4j database.

  Accepted options:
    * `:uri` (required) — e.g. `"bolt://localhost:7687"` or `"neo4j://..."`
    * `:user` / `:password`
    * `:db` — database name (optional)
    * `:fetch_size` — rows per fetch window (`0` keeps driver default)
    * `:max_connections` — pool size (`0` keeps driver default)
    * `:impersonate_user` — user to impersonate for queries (Bolt v5)
    * `:tls` — one of:
        * `nil` (default) — use scheme-driven TLS (`neo4j+s://`, `bolt+ssc://`, …)
        * `{:ca, "path/to/ca.pem"}` — validate the server against this CA
        * `{:mutual, ca: path | nil, cert: path, key: path}` — mutual TLS
        * `:skip_validation` — bypass verification (NOT for production)
    * `:timeout` — milliseconds to wait for the handshake (default 15 000)
  """
  @spec connect(config()) :: {:ok, graph()} | {:error, term()}
  def connect(opts) do
    opts = normalize(opts)
    timeout = Map.get(opts, :timeout, @default_timeout)
    {tls_mode, tls_ca, tls_cert, tls_key} = tls_payload(Map.get(opts, :tls))

    payload = %{
      uri: Map.fetch!(opts, :uri),
      user: Map.get(opts, :user, ""),
      password: Map.get(opts, :password, ""),
      db: Map.get(opts, :db, ""),
      fetch_size: Map.get(opts, :fetch_size, 0),
      max_connections: Map.get(opts, :max_connections, 0),
      impersonate_user: Map.get(opts, :impersonate_user, ""),
      tls_mode: tls_mode,
      tls_ca: tls_ca,
      tls_cert: tls_cert,
      tls_key: tls_key
    }

    ref = Native.connect(payload)
    await(ref, timeout)
  end

  defp tls_payload(nil), do: {"none", "", "", ""}
  defp tls_payload({:ca, ca}) when is_binary(ca), do: {"ca", ca, "", ""}

  defp tls_payload({:mutual, mtls}) do
    ca = Keyword.get(mtls, :ca) || ""
    cert = Keyword.fetch!(mtls, :cert)
    key = Keyword.fetch!(mtls, :key)
    {"mutual", ca, cert, key}
  end

  defp tls_payload(:skip_validation), do: {"skip", "", "", ""}
  defp tls_payload(other), do: raise(ArgumentError, "unsupported :tls option: #{inspect(other)}")

  # ===========================================================================
  # Auto-commit queries
  # ===========================================================================

  @doc "Run a query in auto-commit mode, discarding any rows."
  @spec run(graph(), String.t(), params(), keyword()) :: :ok | {:error, term()}
  def run(graph, cypher, params \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ref = Native.run(graph, cypher, params || %{})
    await(ref, timeout)
  end

  @doc "Run a query in auto-commit mode and return the `%BoltexNif.Summary{}`."
  @spec run_with_summary(graph(), String.t(), params(), keyword()) ::
          {:ok, BoltexNif.Summary.t()} | {:error, term()}
  def run_with_summary(graph, cypher, params \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ref = Native.run_with_summary(graph, cypher, params || %{})
    await(ref, timeout)
  end

  @doc "Run a query in auto-commit mode, collecting all rows."
  @spec execute(graph(), String.t(), params(), keyword()) ::
          {:ok, [row()]} | {:error, term()}
  def execute(graph, cypher, params \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ref = Native.execute(graph, cypher, params || %{})
    await(ref, timeout)
  end

  # ===========================================================================
  # Transactions
  # ===========================================================================

  @doc "Start an explicit transaction. Must be finished with `commit/2` or `rollback/2`."
  @spec begin_transaction(graph(), keyword()) :: {:ok, txn()} | {:error, term()}
  def begin_transaction(graph, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ref = Native.begin_transaction(graph)
    await(ref, timeout)
  end

  @doc "Run a query inside a transaction, returning its `%BoltexNif.Summary{}`."
  @spec txn_run(txn(), String.t(), params(), keyword()) ::
          {:ok, BoltexNif.Summary.t()} | {:error, term()}
  def txn_run(txn, cypher, params \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ref = Native.txn_run(txn, cypher, params || %{})
    await(ref, timeout)
  end

  @doc "Run a query inside a transaction and collect all rows."
  @spec txn_execute(txn(), String.t(), params(), keyword()) ::
          {:ok, [row()]} | {:error, term()}
  def txn_execute(txn, cypher, params \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ref = Native.txn_execute(txn, cypher, params || %{})
    await(ref, timeout)
  end

  @doc """
  Commit a transaction. Returns `{:ok, bookmark}` on Bolt v5 (the bookmark may
  be `nil`) or plain `:ok` otherwise.
  """
  @spec commit(txn(), keyword()) :: :ok | {:ok, String.t() | nil} | {:error, term()}
  def commit(txn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ref = Native.commit(txn)
    await(ref, timeout)
  end

  @doc "Roll back a transaction."
  @spec rollback(txn(), keyword()) :: :ok | {:error, term()}
  def rollback(txn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ref = Native.rollback(txn)
    await(ref, timeout)
  end

  @doc """
  Convenience wrapper: `begin_transaction` → run `fun`, commit on success,
  rollback on `{:error, _}` or raise.
  """
  @spec transaction(graph(), (txn() -> {:ok, any()} | {:error, any()} | any()), keyword()) ::
          {:ok, any()} | {:error, term()}
  def transaction(graph, fun, opts \\ []) do
    with {:ok, txn} <- begin_transaction(graph, opts) do
      try do
        case fun.(txn) do
          {:ok, value} ->
            case commit(txn, opts) do
              :ok -> {:ok, value}
              {:ok, _bookmark} -> {:ok, value}
              {:error, _} = err -> err
            end

          {:error, _} = err ->
            _ = rollback(txn, opts)
            err

          other ->
            case commit(txn, opts) do
              :ok -> {:ok, other}
              {:ok, _bookmark} -> {:ok, other}
              {:error, _} = err -> err
            end
        end
      rescue
        e ->
          _ = rollback(txn, opts)
          reraise e, __STACKTRACE__
      end
    end
  end

  # ===========================================================================
  # Streaming
  # ===========================================================================

  @doc "Start a lazy row stream for `cypher`. Consume with `stream_next/2`."
  @spec stream_start(graph(), String.t(), params(), keyword()) ::
          {:ok, stream()} | {:error, term()}
  def stream_start(graph, cypher, params \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ref = Native.stream_start(graph, cypher, params || %{})
    await(ref, timeout)
  end

  @doc "Fetch the next row. Returns `{:ok, row}`, `:done`, or `{:error, reason}`."
  @spec stream_next(stream(), keyword()) :: {:ok, row()} | :done | {:error, term()}
  def stream_next(stream, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ref = Native.stream_next(stream)
    await(ref, timeout)
  end

  @doc "Drop a stream eagerly (without consuming remaining rows)."
  @spec stream_close(stream(), keyword()) :: :ok
  def stream_close(stream, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ref = Native.stream_close(stream)
    await(ref, timeout)
  end

  # ===========================================================================
  # Internals
  # ===========================================================================

  defp normalize(opts) when is_list(opts), do: Map.new(opts)
  defp normalize(%{} = opts), do: opts

  defp await(ref, timeout) do
    receive do
      {^ref, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end
end
