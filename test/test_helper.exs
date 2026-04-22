skip_live =
  case System.get_env("NEO4J_URI") do
    nil -> [:live]
    "" -> [:live]
    _ -> []
  end

ExUnit.start(exclude: skip_live)
