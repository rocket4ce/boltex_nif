# Comprehensive BoltexNif smoke script.
#
# Usage:
#   NEO4J_URI=bolt://host:7687 NEO4J_USER=neo4j NEO4J_PASSWORD=xxx mix run scripts/smoke.exs
#
# Exits 0 on success, 1 on the first failed assertion.

alias BoltexNif.{Duration, Neo4jError, Node, Path, Point, Relationship}

uri = System.get_env("NEO4J_URI", "bolt://localhost:7687")
user = System.get_env("NEO4J_USER", "neo4j")
password = System.get_env("NEO4J_PASSWORD") || raise "NEO4J_PASSWORD must be set"

IO.puts("==> BoltexNif smoke")
IO.puts("    uri:  #{uri}")
IO.puts("    user: #{user}")

{:ok, g} =
  BoltexNif.connect(
    uri: uri,
    user: user,
    password: password,
    fetch_size: 500,
    max_connections: 4
  )

IO.puts("    connected.")

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

pass = fn label ->
  IO.puts("  \e[32m✓\e[0m #{label}")
end

fail = fn label, detail ->
  IO.puts("  \e[31m✗\e[0m #{label}")
  IO.puts("    #{inspect(detail, pretty: true)}")
  System.halt(1)
end

assert = fn label, cond, detail ->
  if cond, do: pass.(label), else: fail.(label, detail)
end

section = fn title ->
  IO.puts("\n\e[34m▶ #{title}\e[0m")
end

# ---------------------------------------------------------------------------
# 1) scalars + collections
# ---------------------------------------------------------------------------
section.("scalars + collections")

params = %{
  "n" => 42,
  "f" => 3.14,
  "t" => true,
  "s" => "hola",
  "xs" => [1, 2, 3],
  "m" => %{"a" => 1, "b" => "two"},
  "z" => nil
}

{:ok, [row]} =
  BoltexNif.execute(
    g,
    "RETURN $n AS n, $f AS f, $t AS t, $s AS s, $xs AS xs, $m AS m, $z AS z",
    params
  )

assert.("integer", row["n"] == 42, row["n"])
assert.("float", row["f"] == 3.14, row["f"])
assert.("boolean true", row["t"] == true, row["t"])
assert.("string", row["s"] == "hola", row["s"])
assert.("list of ints", row["xs"] == [1, 2, 3], row["xs"])
assert.("map<str,any>", row["m"] == %{"a" => 1, "b" => "two"}, row["m"])
assert.("null", row["z"] == nil, row["z"])

# ---------------------------------------------------------------------------
# 2) graph types (Node / Relationship / Path)
# ---------------------------------------------------------------------------
section.("graph types")

:ok = BoltexNif.run(g, "MATCH (n:Smoke) DETACH DELETE n")

:ok =
  BoltexNif.run(g, """
  MERGE (a:Smoke:Person {name:'A', age: 30})
  MERGE (b:Smoke:Person {name:'B'})
  MERGE (c:Smoke:Person {name:'C'})
  MERGE (a)-[:KNOWS {since: 2020}]->(b)
  MERGE (b)-[:KNOWS {since: 2021}]->(c)
  """)

{:ok, [%{"p" => %Node{} = node_a}]} =
  BoltexNif.execute(g, "MATCH (p:Smoke {name:'A'}) RETURN p")

assert.("node labels contain Person", "Person" in node_a.labels, node_a.labels)
assert.("node property name=A", node_a.properties["name"] == "A", node_a.properties)
assert.("node property age=30 (integer)", node_a.properties["age"] == 30, node_a.properties)

{:ok, [%{"r" => %Relationship{} = rel}]} =
  BoltexNif.execute(
    g,
    "MATCH (:Smoke {name:'A'})-[r:KNOWS]->(:Smoke {name:'B'}) RETURN r"
  )

assert.("relationship type", rel.type == "KNOWS", rel)
assert.("relationship property since=2020", rel.properties["since"] == 2020, rel)

{:ok, [%{"p" => %Path{} = path}]} =
  BoltexNif.execute(
    g,
    "MATCH p = (:Smoke {name:'A'})-[*2]->(:Smoke {name:'C'}) RETURN p LIMIT 1"
  )

assert.("path nodes count = 3", length(path.nodes) == 3, path.nodes)
assert.("path relationships count = 2", length(path.relationships) == 2, path.relationships)

# ---------------------------------------------------------------------------
# 3) temporal + spatial
# ---------------------------------------------------------------------------
section.("temporal + spatial round-trip")

dur = %Duration{months: 14, days: 3, seconds: 45, nanoseconds: 500}

{:ok, [%{"d" => %Duration{} = dur_back}]} =
  BoltexNif.execute(g, "RETURN $d AS d", %{"d" => dur})

assert.("Duration preserved", dur_back == dur, dur_back)

date = ~D[2026-04-22]
time = ~T[09:15:30.123456]
naive = ~N[2026-04-22 09:15:30.123456]

{:ok, [temporal_row]} =
  BoltexNif.execute(
    g,
    "RETURN $d AS d, $t AS t, $ndt AS ndt",
    %{"d" => date, "t" => time, "ndt" => naive}
  )

assert.("Date round-trip", temporal_row["d"] == date, temporal_row["d"])
assert.("Time round-trip", temporal_row["t"] == time, temporal_row["t"])
assert.("NaiveDateTime round-trip", temporal_row["ndt"] == naive, temporal_row["ndt"])

point = %Point{srid: 7203, x: 1.5, y: 2.5}

{:ok, [%{"p" => %Point{} = point_back}]} =
  BoltexNif.execute(g, "RETURN $p AS p", %{"p" => point})

assert.(
  "Point2D round-trip",
  point_back.srid == 7203 and point_back.x == 1.5 and point_back.y == 2.5 and point_back.z == nil,
  point_back
)

# ---------------------------------------------------------------------------
# 4) transactions
# ---------------------------------------------------------------------------
section.("transactions")

:ok = BoltexNif.run(g, "MATCH (n:SmokeTxn) DETACH DELETE n")

{:ok, value} =
  BoltexNif.transaction(g, fn txn ->
    {:ok, _} = BoltexNif.txn_run(txn, "CREATE (:SmokeTxn {x:1})")
    {:ok, _} = BoltexNif.txn_run(txn, "CREATE (:SmokeTxn {x:2})")
    {:ok, :done}
  end)

assert.("transaction commit returns :ok tuple", value == :done, value)

{:ok, [%{"c" => committed}]} =
  BoltexNif.execute(g, "MATCH (n:SmokeTxn) RETURN count(n) AS c")

assert.("commit persisted 2 nodes", committed == 2, committed)

{:error, :rollback_probe} =
  BoltexNif.transaction(g, fn txn ->
    {:ok, _} = BoltexNif.txn_run(txn, "CREATE (:SmokeTxn {x:999})")
    {:error, :rollback_probe}
  end)

{:ok, [%{"c" => still_two}]} =
  BoltexNif.execute(g, "MATCH (n:SmokeTxn) RETURN count(n) AS c")

assert.("rollback discarded the write (still 2)", still_two == 2, still_two)

# ---------------------------------------------------------------------------
# 5) streaming
# ---------------------------------------------------------------------------
section.("streaming")

{:ok, stream} =
  BoltexNif.stream_start(g, "UNWIND range(1, 5) AS i RETURN i")

streamed =
  Stream.repeatedly(fn -> BoltexNif.stream_next(stream) end)
  |> Enum.take_while(&(&1 != :done))
  |> Enum.map(fn {:ok, %{"i" => i}} -> i end)

assert.("stream yielded [1..5]", streamed == [1, 2, 3, 4, 5], streamed)

# ---------------------------------------------------------------------------
# 6) summary (ResultSummary + Counters)
# ---------------------------------------------------------------------------
section.("summary / counters")

{:ok, summary} =
  BoltexNif.run_with_summary(g, "CREATE (:SmokeAudit {n:1}), (:SmokeAudit {n:2})")

assert.("summary.stats.nodes_created == 2", summary.stats.nodes_created == 2, summary.stats)
assert.("summary.query_type is a string", is_binary(summary.query_type), summary.query_type)

# ---------------------------------------------------------------------------
# 7) structured Neo4jError
# ---------------------------------------------------------------------------
section.("structured Neo4j error")

{:error, {:neo4j, %Neo4jError{} = err}} =
  BoltexNif.execute(g, "RETURN $missing.x")

assert.("error.code is a string", is_binary(err.code), err)
assert.("error.kind is an atom", is_atom(err.kind), err)

assert.(
  "Neo4jError.retryable?/1 is a boolean",
  is_boolean(Neo4jError.retryable?(err)),
  err
)

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
section.("cleanup")

:ok = BoltexNif.run(g, "MATCH (n:Smoke|SmokeTxn|SmokeAudit) DETACH DELETE n")
pass.("test nodes removed")

IO.puts("\n\e[32m══ BoltexNif smoke passed ══\e[0m\n")
