# Start Neo4j only when the caller provides credentials. Tests tagged
# `:live` are excluded otherwise so `mix test` stays fast offline.
live_opts =
  case System.get_env("NEO4J_URI") do
    nil -> nil
    "" -> nil
    uri ->
      password =
        System.get_env("NEO4J_PASSWORD") ||
          raise "NEO4J_PASSWORD must be set when NEO4J_URI is provided"

      [
        uri: uri,
        user: System.get_env("NEO4J_USER", "neo4j"),
        password: password,
        fetch_size: 500,
        max_connections: 4
      ]
  end

base_excludes =
  case live_opts do
    nil -> [:live]
    _ -> []
  end

if live_opts do
  {:ok, _pid} = PhoenixNeo4j.Neo4j.start_link(live_opts)
end

# Stress tests are opt-in; include them with `--include stress`.
ExUnit.start(exclude: base_excludes ++ [:stress])
