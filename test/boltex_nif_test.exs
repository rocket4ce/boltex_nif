defmodule BoltexNifTest do
  use ExUnit.Case, async: false

  alias BoltexNif.{Node, Relationship, Path, Point, Duration, Summary}

  @moduletag :live

  setup_all do
    uri = System.get_env("NEO4J_URI", "bolt://localhost:7687")
    user = System.get_env("NEO4J_USER", "neo4j")
    password = System.get_env("NEO4J_PASSWORD", "boltex_nif_pass")

    case BoltexNif.connect(uri: uri, user: user, password: password) do
      {:ok, graph} ->
        :ok = BoltexNif.run(graph, "MATCH (n:BoltexNifTest) DETACH DELETE n")
        %{graph: graph}

      {:error, reason} ->
        raise "Failed to connect to Neo4j at #{uri}: #{inspect(reason)}"
    end
  end

  setup %{graph: graph} do
    :ok = BoltexNif.run(graph, "MATCH (n:BoltexNifTest) DETACH DELETE n")
    :ok
  end

  describe "scalars" do
    test "round-trip of primitive types", %{graph: graph} do
      params = %{
        "n" => 42,
        "f" => 3.5,
        "t" => true,
        "s" => "hello",
        "xs" => [1, 2, 3],
        "m" => %{"a" => 1, "b" => "two"},
        "z" => nil
      }

      assert {:ok, [row]} =
               BoltexNif.execute(
                 graph,
                 "RETURN $n AS n, $f AS f, $t AS t, $s AS s, $xs AS xs, $m AS m, $z AS z",
                 params
               )

      assert row["n"] == 42
      assert row["f"] == 3.5
      assert row["t"] == true
      assert row["s"] == "hello"
      assert row["xs"] == [1, 2, 3]
      assert row["m"] == %{"a" => 1, "b" => "two"}
      assert row["z"] == nil
    end
  end

  describe "graph types" do
    test "node round-trip", %{graph: graph} do
      :ok =
        BoltexNif.run(
          graph,
          "CREATE (:BoltexNifTest:Person {name: $name, age: $age})",
          %{"name" => "Alice", "age" => 30}
        )

      assert {:ok, [%{"p" => %Node{} = node}]} =
               BoltexNif.execute(graph, "MATCH (p:BoltexNifTest) RETURN p")

      assert "Person" in node.labels
      assert "BoltexNifTest" in node.labels
      assert node.properties["name"] == "Alice"
      assert node.properties["age"] == 30
    end

    test "relationship round-trip", %{graph: graph} do
      :ok =
        BoltexNif.run(
          graph,
          "CREATE (a:BoltexNifTest {name: 'A'})-[:KNOWS {since: 2020}]->(b:BoltexNifTest {name: 'B'})"
        )

      assert {:ok, [%{"r" => %Relationship{} = rel}]} =
               BoltexNif.execute(
                 graph,
                 "MATCH (:BoltexNifTest)-[r:KNOWS]->(:BoltexNifTest) RETURN r"
               )

      assert rel.type == "KNOWS"
      assert rel.properties["since"] == 2020
    end

    test "path decoding", %{graph: graph} do
      :ok =
        BoltexNif.run(
          graph,
          "CREATE (a:BoltexNifTest {id: 1})-[:R]->(b:BoltexNifTest {id: 2})-[:R]->(c:BoltexNifTest {id: 3})"
        )

      assert {:ok, [%{"p" => %Path{} = path}]} =
               BoltexNif.execute(
                 graph,
                 "MATCH p = (:BoltexNifTest {id: 1})-[*2]->(:BoltexNifTest {id: 3}) RETURN p LIMIT 1"
               )

      assert length(path.nodes) == 3
      assert length(path.relationships) == 2
    end
  end

  describe "temporal & spatial" do
    test "duration round-trip", %{graph: graph} do
      dur = %Duration{months: 14, days: 3, seconds: 45, nanoseconds: 500}

      assert {:ok, [%{"d" => %Duration{} = out}]} =
               BoltexNif.execute(graph, "RETURN $d AS d", %{"d" => dur})

      assert out == dur
    end

    test "date/time/naive-datetime round-trip", %{graph: graph} do
      d = ~D[2026-04-22]
      t = ~T[09:15:30.123456]
      ndt = ~N[2026-04-22 09:15:30.123456]

      assert {:ok, [row]} =
               BoltexNif.execute(
                 graph,
                 "RETURN $d AS d, $t AS t, $ndt AS ndt",
                 %{"d" => d, "t" => t, "ndt" => ndt}
               )

      assert row["d"] == d
      assert row["t"] == t
      assert row["ndt"] == ndt
    end

    test "point2d round-trip", %{graph: graph} do
      p = %Point{srid: 7203, x: 1.5, y: 2.5}

      assert {:ok, [%{"p" => %Point{} = out}]} =
               BoltexNif.execute(graph, "RETURN $p AS p", %{"p" => p})

      assert out.srid == 7203
      assert out.x == 1.5
      assert out.y == 2.5
      assert out.z == nil
    end
  end

  describe "error handling" do
    test "invalid cypher yields a structured Neo4j error", %{graph: graph} do
      assert {:error, {:neo4j, %BoltexNif.Neo4jError{} = err}} =
               BoltexNif.execute(graph, "RETURN $x.y")

      assert is_binary(err.code)
      assert is_binary(err.message)
      assert err.kind in [:client_other, :client_unknown, :protocol_violation]
    end
  end

  describe "run_with_summary" do
    test "returns counters for writes", %{graph: graph} do
      assert {:ok, %Summary{stats: stats} = summary} =
               BoltexNif.run_with_summary(
                 graph,
                 "CREATE (:BoltexNifTest {x: 1})"
               )

      assert stats.nodes_created == 1
      assert stats.labels_added == 1
      assert stats.properties_set == 1
      assert is_binary(summary.query_type)
    end
  end

  describe "transactions" do
    test "commit persists writes", %{graph: graph} do
      {:ok, txn} = BoltexNif.begin_transaction(graph)
      {:ok, _s} = BoltexNif.txn_run(txn, "CREATE (:BoltexNifTest {x: 1})")
      {:ok, _s} = BoltexNif.txn_run(txn, "CREATE (:BoltexNifTest {x: 2})")

      assert {:ok, [%{"c" => 2}]} =
               BoltexNif.txn_execute(txn, "MATCH (n:BoltexNifTest) RETURN count(n) AS c")

      case BoltexNif.commit(txn) do
        :ok -> :ok
        {:ok, _bookmark} -> :ok
      end

      assert {:ok, [%{"c" => 2}]} =
               BoltexNif.execute(graph, "MATCH (n:BoltexNifTest) RETURN count(n) AS c")
    end

    test "rollback discards writes", %{graph: graph} do
      {:ok, txn} = BoltexNif.begin_transaction(graph)
      {:ok, _s} = BoltexNif.txn_run(txn, "CREATE (:BoltexNifTest {x: 1})")
      :ok = BoltexNif.rollback(txn)

      assert {:ok, [%{"c" => 0}]} =
               BoltexNif.execute(graph, "MATCH (n:BoltexNifTest) RETURN count(n) AS c")
    end

    test "using transaction/2 helper commits on :ok", %{graph: graph} do
      {:ok, value} =
        BoltexNif.transaction(graph, fn txn ->
          {:ok, _s} = BoltexNif.txn_run(txn, "CREATE (:BoltexNifTest {x: 1})")
          {:ok, :done}
        end)

      assert value == :done

      assert {:ok, [%{"c" => 1}]} =
               BoltexNif.execute(graph, "MATCH (n:BoltexNifTest) RETURN count(n) AS c")
    end

    test "using transaction/2 helper rolls back on {:error, _}", %{graph: graph} do
      assert {:error, :boom} =
               BoltexNif.transaction(graph, fn txn ->
                 {:ok, _s} = BoltexNif.txn_run(txn, "CREATE (:BoltexNifTest {x: 1})")
                 {:error, :boom}
               end)

      assert {:ok, [%{"c" => 0}]} =
               BoltexNif.execute(graph, "MATCH (n:BoltexNifTest) RETURN count(n) AS c")
    end
  end

  describe "streaming" do
    test "lazy row iteration", %{graph: graph} do
      for i <- 1..5 do
        :ok =
          BoltexNif.run(graph, "CREATE (:BoltexNifTest {i: $i})", %{"i" => i})
      end

      {:ok, stream} =
        BoltexNif.stream_start(
          graph,
          "MATCH (n:BoltexNifTest) RETURN n.i AS i ORDER BY n.i"
        )

      rows = stream_drain(stream, [])
      assert rows == [1, 2, 3, 4, 5]
    end
  end

  defp stream_drain(stream, acc) do
    case BoltexNif.stream_next(stream) do
      {:ok, %{"i" => i}} -> stream_drain(stream, [i | acc])
      :done -> Enum.reverse(acc)
      other -> flunk("unexpected stream_next response: #{inspect(other)}")
    end
  end
end
