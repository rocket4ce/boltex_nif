defmodule PhoenixNeo4j.Neo4j do
  @moduledoc """
  Supervised entry point to the Neo4j driver.

  The GenServer opens one `BoltexNif` connection pool on boot and stores the
  opaque graph reference in `:persistent_term`. Callers go straight through the
  reference (no GenServer bottleneck) — BoltexNif's internal pool handles
  concurrency.
  """

  use GenServer
  require Logger

  @key {__MODULE__, :graph}

  # ---- Public API ----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the shared `BoltexNif` graph reference."
  @spec graph() :: BoltexNif.graph()
  def graph do
    :persistent_term.get(@key)
  rescue
    ArgumentError ->
      raise "PhoenixNeo4j.Neo4j not started yet — check your supervision tree"
  end

  @doc "Run a Cypher query, discarding rows."
  @spec run(String.t(), map() | nil) :: :ok | {:error, term()}
  def run(cypher, params \\ nil), do: BoltexNif.run(graph(), cypher, params)

  @doc "Run a Cypher query, returning all rows."
  @spec execute(String.t(), map() | nil) :: {:ok, [map()]} | {:error, term()}
  def execute(cypher, params \\ nil), do: BoltexNif.execute(graph(), cypher, params)

  @doc "Open a transaction (wraps `BoltexNif.begin_transaction/2`)."
  defdelegate begin_transaction(opts \\ []), to: BoltexNif, as: :begin_transaction

  @doc "Shortcut for the transaction helper in `BoltexNif`."
  def transaction(fun, opts \\ []), do: BoltexNif.transaction(graph(), fun, opts)

  # ---- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    uri = Keyword.fetch!(opts, :uri)
    Logger.info("[PhoenixNeo4j.Neo4j] connecting to #{uri}")

    case BoltexNif.connect(opts) do
      {:ok, graph} ->
        :persistent_term.put(@key, graph)
        Logger.info("[PhoenixNeo4j.Neo4j] connected")
        {:ok, %{graph: graph, opts: opts}}

      {:error, reason} ->
        Logger.error("[PhoenixNeo4j.Neo4j] connect failed: #{inspect(reason)}")
        {:stop, {:connect_failed, reason}}
    end
  end
end
