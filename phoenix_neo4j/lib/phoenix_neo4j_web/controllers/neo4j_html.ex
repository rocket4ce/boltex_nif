defmodule PhoenixNeo4jWeb.Neo4jHTML do
  @moduledoc """
  Templates for the Neo4j demo pages.
  """
  use PhoenixNeo4jWeb, :html

  embed_templates "neo4j_html/*"

  @doc """
  Formats a Cypher `timestamp()` value (ms since epoch) as a readable UTC string.
  """
  def format_ts(nil), do: "—"

  def format_ts(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end
end
