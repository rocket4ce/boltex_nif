defmodule PhoenixNeo4j.Neo4jTest do
  @moduledoc """
  End-to-end exercise of `PhoenixNeo4j.Neo4j` (and therefore `BoltexNif`):
  type round-trips, transactions, streaming, summaries, concurrency, and
  every error path we can deliberately trigger.
  """
  use PhoenixNeo4j.Neo4jCase, async: false

  @moduletag :live

  describe "scalars + collections" do
    test "integers / floats / booleans / strings / null" do
      params = %{"n" => 42, "f" => 3.14, "t" => true, "s" => "hola", "z" => nil}

      {:ok, [row]} =
        Neo4j.execute("RETURN $n AS n, $f AS f, $t AS t, $s AS s, $z AS z", params)

      assert row["n"] == 42
      assert row["f"] == 3.14
      assert row["t"] == true
      assert row["s"] == "hola"
      assert row["z"] == nil
    end

    test "negative / large integers" do
      {:ok, [row]} =
        Neo4j.execute("RETURN $a AS a, $b AS b, $c AS c", %{
          "a" => -1,
          "b" => 9_223_372_036_854_775_807,
          "c" => -9_223_372_036_854_775_808
        })

      assert row["a"] == -1
      assert row["b"] == 9_223_372_036_854_775_807
      assert row["c"] == -9_223_372_036_854_775_808
    end

    test "UTF-8, emojis, special characters" do
      payload = "áéíóú ñ 漢字 ✨ 🚀 \"quoted\" \n line-break \t tab"
      {:ok, [%{"s" => back}]} = Neo4j.execute("RETURN $s AS s", %{"s" => payload})
      assert back == payload
    end

    test "nested list / map" do
      params = %{
        "xs" => [1, [2, 3], [[4, 5], 6]],
        "m" => %{"a" => 1, "b" => %{"c" => [true, nil, "x"]}}
      }

      {:ok, [row]} = Neo4j.execute("RETURN $xs AS xs, $m AS m", params)
      assert row["xs"] == [1, [2, 3], [[4, 5], 6]]
      assert row["m"] == %{"a" => 1, "b" => %{"c" => [true, nil, "x"]}}
    end

    test "empty list / empty map round-trip" do
      {:ok, [row]} = Neo4j.execute("RETURN $xs AS xs, $m AS m", %{"xs" => [], "m" => %{}})
      assert row["xs"] == []
      assert row["m"] == %{}
    end
  end

  describe "graph types" do
    setup do
      :ok =
        Neo4j.run("""
        CREATE (a:TestPerson {name:'Ada', age: 36})
        CREATE (b:TestPerson {name:'Grace'})
        CREATE (c:TestPerson {name:'Linus'})
        MERGE (a)-[:KNOWS {since: 2020}]->(b)
        MERGE (b)-[:KNOWS {since: 2021}]->(c)
        """)

      :ok
    end

    test "decodes Node struct" do
      {:ok, [%{"p" => %Node{} = node}]} =
        Neo4j.execute("MATCH (p:TestPerson {name:'Ada'}) RETURN p")

      assert "TestPerson" in node.labels
      assert node.properties["name"] == "Ada"
      assert node.properties["age"] == 36
    end

    test "decodes Relationship struct" do
      {:ok, [%{"r" => %Relationship{} = rel}]} =
        Neo4j.execute(
          "MATCH (:TestPerson {name:'Ada'})-[r:KNOWS]->(:TestPerson {name:'Grace'}) RETURN r"
        )

      assert rel.type == "KNOWS"
      assert rel.properties["since"] == 2020
      assert is_integer(rel.start_node_id)
      assert is_integer(rel.end_node_id)
    end

    test "decodes Path with alternating nodes and unbound relationships" do
      {:ok, [%{"p" => %Path{} = path}]} =
        Neo4j.execute(
          "MATCH p = (:TestPerson {name:'Ada'})-[*2]->(:TestPerson {name:'Linus'}) RETURN p"
        )

      assert length(path.nodes) == 3
      assert length(path.relationships) == 2
      assert Enum.all?(path.relationships, &match?(%UnboundRelationship{}, &1))
    end

    test "node with null property" do
      {:ok, [%{"p" => %Node{} = node}]} =
        Neo4j.execute("MATCH (p:TestPerson {name:'Grace'}) RETURN p")

      refute Map.has_key?(node.properties, "age")
    end
  end

  describe "temporal + spatial" do
    test "Duration round-trip" do
      d = %Duration{months: 14, days: 3, seconds: 45, nanoseconds: 500}
      {:ok, [%{"d" => back}]} = Neo4j.execute("RETURN $d AS d", %{"d" => d})
      assert back == d
    end

    test "Date / Time / NaiveDateTime round-trip" do
      d = ~D[2026-04-22]
      t = ~T[09:15:30.123456]
      ndt = ~N[2026-04-22 09:15:30.123456]

      {:ok, [row]} =
        Neo4j.execute(
          "RETURN $d AS d, $t AS t, $ndt AS ndt",
          %{"d" => d, "t" => t, "ndt" => ndt}
        )

      assert row["d"] == d
      assert row["t"] == t
      assert row["ndt"] == ndt
    end

    test "Point2D round-trip" do
      p = %Point{srid: 7203, x: 1.5, y: 2.5}
      {:ok, [%{"p" => back}]} = Neo4j.execute("RETURN $p AS p", %{"p" => p})

      assert back.srid == 7203
      assert back.x == 1.5
      assert back.y == 2.5
      assert back.z == nil
    end

    test "Point3D (via Cypher `point` function)" do
      {:ok, [%{"p" => %Point{} = back}]} =
        Neo4j.execute(
          "RETURN point({srid: $srid, x: $x, y: $y, z: $z}) AS p",
          %{"srid" => 9157, "x" => 1.0, "y" => 2.0, "z" => 3.0}
        )

      assert back.srid == 9157
      assert back.z == 3.0
    end
  end

  describe "run / execute / run_with_summary" do
    test "run/2 returns :ok, execute/2 returns rows" do
      assert :ok = Neo4j.run("CREATE (:TestNode {x: 1})")
      assert {:ok, [%{"n" => 1}]} = Neo4j.execute("RETURN 1 AS n")
    end

    test "run_with_summary/2 exposes counters" do
      {:ok, summary} =
        BoltexNif.run_with_summary(
          Neo4j.graph(),
          "CREATE (:TestAudit {a:1}), (:TestAudit {a:2})"
        )

      assert summary.stats.nodes_created == 2
      assert summary.stats.properties_set == 2
      assert summary.stats.labels_added >= 1
      assert is_binary(summary.query_type)
    end

    test "execute with no rows returns empty list" do
      assert {:ok, []} = Neo4j.execute("MATCH (n:TestNonexistent) RETURN n")
    end

    test "large result set (1000 rows)" do
      {:ok, rows} = Neo4j.execute("UNWIND range(1, 1000) AS i RETURN i")
      assert length(rows) == 1000
      assert List.first(rows) == %{"i" => 1}
      assert List.last(rows) == %{"i" => 1000}
    end
  end

  describe "transactions" do
    test "commit persists writes" do
      {:ok, txn} = BoltexNif.begin_transaction(Neo4j.graph())
      assert {:ok, _summary} = BoltexNif.txn_run(txn, "CREATE (:TestTx {a:1})")
      assert {:ok, _summary} = BoltexNif.txn_run(txn, "CREATE (:TestTx {a:2})")

      assert {:ok, [%{"c" => 2}]} =
               BoltexNif.txn_execute(txn, "MATCH (n:TestTx) RETURN count(n) AS c")

      commit_result = BoltexNif.commit(txn)
      assert match?(:ok, commit_result) or match?({:ok, _bookmark}, commit_result)

      assert {:ok, [%{"c" => 2}]} =
               Neo4j.execute("MATCH (n:TestTx) RETURN count(n) AS c")
    end

    test "rollback discards writes" do
      {:ok, txn} = BoltexNif.begin_transaction(Neo4j.graph())
      {:ok, _} = BoltexNif.txn_run(txn, "CREATE (:TestTx {a:99})")
      :ok = BoltexNif.rollback(txn)

      assert {:ok, [%{"c" => 0}]} =
               Neo4j.execute("MATCH (n:TestTx) RETURN count(n) AS c")
    end

    test "transaction helper commits on {:ok, _}" do
      assert {:ok, :done} =
               Neo4j.transaction(fn txn ->
                 {:ok, _} = BoltexNif.txn_run(txn, "CREATE (:TestTx {a:1})")
                 {:ok, :done}
               end)

      assert {:ok, [%{"c" => 1}]} =
               Neo4j.execute("MATCH (n:TestTx) RETURN count(n) AS c")
    end

    test "transaction helper rolls back on {:error, _}" do
      assert {:error, :boom} =
               Neo4j.transaction(fn txn ->
                 {:ok, _} = BoltexNif.txn_run(txn, "CREATE (:TestTx {a:1})")
                 {:error, :boom}
               end)

      assert {:ok, [%{"c" => 0}]} =
               Neo4j.execute("MATCH (n:TestTx) RETURN count(n) AS c")
    end

    test "transaction helper re-raises on exception + rolls back" do
      assert_raise RuntimeError, "boom", fn ->
        Neo4j.transaction(fn txn ->
          {:ok, _} = BoltexNif.txn_run(txn, "CREATE (:TestTx {a:1})")
          raise "boom"
        end)
      end

      assert {:ok, [%{"c" => 0}]} =
               Neo4j.execute("MATCH (n:TestTx) RETURN count(n) AS c")
    end

    test "txn_run after commit returns an error" do
      {:ok, txn} = BoltexNif.begin_transaction(Neo4j.graph())
      {:ok, _} = BoltexNif.txn_run(txn, "RETURN 1")
      _ = BoltexNif.commit(txn)

      assert {:error, _reason} = BoltexNif.txn_run(txn, "RETURN 2")
    end
  end

  describe "streaming" do
    test "yields rows lazily until :done" do
      {:ok, stream} = BoltexNif.stream_start(Neo4j.graph(), "UNWIND range(1, 5) AS i RETURN i")

      values =
        Stream.repeatedly(fn -> BoltexNif.stream_next(stream) end)
        |> Enum.take_while(&(&1 != :done))
        |> Enum.map(fn {:ok, row} -> row["i"] end)

      assert values == [1, 2, 3, 4, 5]
    end

    test "stream_next on a closed stream errors out" do
      {:ok, stream} = BoltexNif.stream_start(Neo4j.graph(), "RETURN 1 AS i")
      {:ok, _row} = BoltexNif.stream_next(stream)
      assert :done = BoltexNif.stream_next(stream)
      assert {:error, :closed} = BoltexNif.stream_next(stream)
    end

    test "stream_close is idempotent" do
      {:ok, stream} = BoltexNif.stream_start(Neo4j.graph(), "UNWIND range(1, 100) AS i RETURN i")
      assert :ok = BoltexNif.stream_close(stream)
      assert :ok = BoltexNif.stream_close(stream)
    end
  end

  describe "errors" do
    test "invalid cypher → structured Neo4jError" do
      assert {:error, {:neo4j, %Neo4jError{} = err}} =
               Neo4j.execute("this is not cypher")

      assert is_binary(err.code)
      assert String.starts_with?(err.code, "Neo.")
      assert is_binary(err.message)
      assert is_atom(err.kind)
    end

    test "missing parameter → structured error" do
      assert {:error, {:neo4j, %Neo4jError{} = err}} =
               Neo4j.execute("RETURN $nope.x")

      assert err.code =~ "ParameterMissing" or err.code =~ "SyntaxError"
    end

    test "Neo4jError.retryable?/1 is boolean" do
      {:error, {:neo4j, err}} = Neo4j.execute("this is not cypher")
      assert is_boolean(Neo4jError.retryable?(err))
    end

    test "decoding Elixir struct with unsupported __struct__ bubbles as :argument" do
      assert {:error, {:argument, msg}} =
               Neo4j.execute("RETURN $x", %{"x" => %URI{}})

      assert msg =~ "unsupported struct"
    end

    test "timeout bubbles when caller's timeout is 0" do
      # Zero timeout guarantees the `receive` expires before the NIF answers.
      assert {:error, :timeout} =
               BoltexNif.execute(Neo4j.graph(), "UNWIND range(1, 100000) AS i RETURN i", %{},
                 timeout: 0
               )
    end

    test "dividing by zero raises an arithmetic error" do
      assert {:error, {:neo4j, %Neo4jError{} = err}} =
               Neo4j.execute("RETURN 1/0 AS x")

      assert err.code =~ "Arithmetic" or err.message =~ "division"
    end
  end

  describe "concurrency" do
    test "parallel queries share the pool without interference" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            {:ok, [%{"n" => n}]} =
              Neo4j.execute("RETURN $i AS n", %{"i" => i})

            n
          end)
        end

      assert Enum.sort(Task.await_many(tasks, 30_000)) == Enum.to_list(1..20)
    end
  end
end
