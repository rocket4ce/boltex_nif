defmodule PhoenixNeo4j.Neo4jCase do
  @moduledoc """
  Test case for anything that exercises Neo4j through `PhoenixNeo4j.Neo4j`.

  Every test is tagged `:live` (so the suite skips without a live DB) and the
  setup clears any labels that look test-owned (anything starting with `Test`,
  plus the demo `:Greeter`) both before the test starts and after it ends.
  """

  use ExUnit.CaseTemplate

  alias PhoenixNeo4j.Neo4j

  @cleanup_cypher """
  MATCH (n)
  WHERE any(l IN labels(n) WHERE l = 'Greeter' OR l STARTS WITH 'Test')
  DETACH DELETE n
  """

  using do
    quote do
      alias BoltexNif.{Duration, Neo4jError, Node, Path, Point, Relationship, UnboundRelationship}
      alias PhoenixNeo4j.Neo4j
      import PhoenixNeo4j.Neo4jCase, only: [cleanup_neo4j!: 0]
    end
  end

  setup _tags do
    cleanup_neo4j!()
    on_exit(fn -> if Process.whereis(Neo4j), do: cleanup_neo4j!() end)
    :ok
  end

  @doc "Wipe all test-owned nodes/relationships."
  def cleanup_neo4j! do
    :ok = Neo4j.run(@cleanup_cypher)
  end
end
