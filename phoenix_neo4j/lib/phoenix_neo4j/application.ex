defmodule PhoenixNeo4j.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        PhoenixNeo4jWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:phoenix_neo4j, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: PhoenixNeo4j.PubSub}
      ] ++
        neo4j_children() ++
        [
          # Start to serve requests, typically the last entry
          PhoenixNeo4jWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PhoenixNeo4j.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PhoenixNeo4jWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp neo4j_children do
    if Application.get_env(:phoenix_neo4j, :start_neo4j, true) do
      [{PhoenixNeo4j.Neo4j, Application.fetch_env!(:phoenix_neo4j, :neo4j)}]
    else
      []
    end
  end
end
