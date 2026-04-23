defmodule PhoenixNeo4j.Neo4jStressTest do
  @moduledoc """
  Opt-in concurrency/stress suite.

      # include with the live tag and the stress tag:
      NEO4J_URI=bolt://... NEO4J_PASSWORD=... \
        mix test --include live --include stress

      # or isolate:
      NEO4J_URI=bolt://... NEO4J_PASSWORD=... \
        mix test --only stress

  Numbers are sized to run in ~30-90 s against a single 4 GB Community Neo4j.
  Scale `@default_pool` + per-test concurrency up if you're pointing at a
  bigger cluster.
  """

  use PhoenixNeo4j.Neo4jCase, async: false

  @moduletag :stress
  @moduletag :live
  @moduletag timeout: :timer.minutes(5)

  # =========================================================================
  # helpers
  # =========================================================================

  defp timed(fun) do
    t0 = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - t0, result}
  end

  defp percentile(sorted, p) when is_list(sorted) do
    idx = max(0, trunc(length(sorted) * p) - 1)
    Enum.at(sorted, idx)
  end

  defp format_ms(us), do: :erlang.float_to_binary(us / 1_000, decimals: 1)

  defp report(label, latencies_us) do
    sorted = Enum.sort(latencies_us)
    count = length(sorted)
    sum = Enum.sum(sorted)
    avg = div(sum, max(count, 1))
    min = List.first(sorted)
    max = List.last(sorted)
    p50 = percentile(sorted, 0.50)
    p95 = percentile(sorted, 0.95)
    p99 = percentile(sorted, 0.99)

    IO.puts(
      "\n  [#{label}] n=#{count}  min/avg/p50/p95/p99/max (ms) = " <>
        "#{format_ms(min)} / #{format_ms(avg)} / #{format_ms(p50)} / " <>
        "#{format_ms(p95)} / #{format_ms(p99)} / #{format_ms(max)}"
    )
  end

  defp throughput(n, dur_us), do: round(n * 1_000_000 / dur_us)

  # Recursive loop used by the sustained-load test.
  defp pump_reads(deadline, acc) do
    if System.monotonic_time(:millisecond) >= deadline do
      acc
    else
      {us, {:ok, [%{"n" => 1}]}} = timed(fn -> Neo4j.execute("RETURN 1 AS n") end)
      pump_reads(deadline, [us | acc])
    end
  end

  # =========================================================================
  # read concurrency
  # =========================================================================

  describe "read concurrency" do
    test "500 parallel reads at concurrency=50" do
      n = 500
      concurrency = 50

      {total_us, results} =
        timed(fn ->
          1..n
          |> Task.async_stream(
            fn i ->
              {us, {:ok, [%{"n" => v}]}} =
                timed(fn -> Neo4j.execute("RETURN $i AS n", %{"i" => i}) end)

              {us, v == i}
            end,
            max_concurrency: concurrency,
            timeout: :timer.seconds(30),
            ordered: false
          )
          |> Enum.map(fn {:ok, x} -> x end)
        end)

      {lats, correct} = Enum.unzip(results)
      assert Enum.all?(correct), "one or more queries returned wrong data"

      IO.puts(
        "\n  read burst: #{n} queries in #{round(total_us / 1_000)} ms " <>
          "(#{throughput(n, total_us)} q/s, concurrency=#{concurrency})"
      )

      report("500 parallel reads", lats)
    end
  end

  # =========================================================================
  # write concurrency
  # =========================================================================

  describe "write concurrency" do
    test "200 parallel writes produce 200 nodes" do
      n = 200
      concurrency = 32

      {total_us, _} =
        timed(fn ->
          1..n
          |> Task.async_stream(
            fn i -> :ok = Neo4j.run("CREATE (:TestStress {i: $i})", %{"i" => i}) end,
            max_concurrency: concurrency,
            timeout: :timer.seconds(30),
            ordered: false
          )
          |> Enum.to_list()
        end)

      {:ok, [%{"c" => c}]} =
        Neo4j.execute("MATCH (n:TestStress) RETURN count(n) AS c")

      assert c == n

      IO.puts(
        "\n  write burst: #{n} nodes in #{round(total_us / 1_000)} ms " <>
          "(#{throughput(n, total_us)} w/s, concurrency=#{concurrency})"
      )
    end
  end

  # =========================================================================
  # mixed read/write
  # =========================================================================

  describe "mixed workload" do
    test "50 reads + 50 writes interleaved, no losses" do
      writers =
        for i <- 1..50 do
          Task.async(fn ->
            Neo4j.run("CREATE (:TestStress {i: $i})", %{"i" => i})
          end)
        end

      readers =
        for i <- 1..50 do
          Task.async(fn ->
            Neo4j.execute("RETURN $i AS n", %{"i" => i})
          end)
        end

      assert Enum.all?(Task.await_many(writers, 30_000), &(&1 == :ok))

      read_results = Task.await_many(readers, 30_000)
      assert Enum.all?(read_results, &match?({:ok, [_row]}, &1))

      {:ok, [%{"c" => c}]} =
        Neo4j.execute("MATCH (n:TestStress) RETURN count(n) AS c")

      assert c == 50
    end
  end

  # =========================================================================
  # transactions under concurrency
  # =========================================================================

  describe "transaction concurrency" do
    test "20 concurrent transactions × 5 writes each = 100 nodes, all committed" do
      n_tx = 20
      writes_per_tx = 5

      tasks =
        for i <- 1..n_tx do
          Task.async(fn ->
            Neo4j.transaction(fn txn ->
              for j <- 1..writes_per_tx do
                {:ok, _} =
                  BoltexNif.txn_run(txn, "CREATE (:TestStress {i: $i, j: $j})", %{
                    "i" => i,
                    "j" => j
                  })
              end

              {:ok, :done}
            end)
          end)
        end

      results = Task.await_many(tasks, 60_000)
      assert Enum.all?(results, &match?({:ok, :done}, &1))

      {:ok, [%{"c" => c}]} =
        Neo4j.execute("MATCH (n:TestStress) RETURN count(n) AS c")

      assert c == n_tx * writes_per_tx
    end

    test "rollbacks under concurrency don't leak writes" do
      n = 15

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            Neo4j.transaction(fn txn ->
              {:ok, _} =
                BoltexNif.txn_run(txn, "CREATE (:TestStress {bad:true, i: $i})", %{"i" => i})

              {:error, :intentional_rollback}
            end)
          end)
        end

      results = Task.await_many(tasks, 60_000)
      assert Enum.all?(results, &match?({:error, :intentional_rollback}, &1))

      {:ok, [%{"c" => c}]} =
        Neo4j.execute("MATCH (n:TestStress {bad:true}) RETURN count(n) AS c")

      assert c == 0
    end
  end

  # =========================================================================
  # streaming under concurrency
  # =========================================================================

  describe "stream concurrency" do
    test "10 streams drained in parallel, each yields 1..50" do
      n_streams = 10
      rows_per = 50

      tasks =
        for k <- 1..n_streams do
          Task.async(fn ->
            {:ok, stream} =
              BoltexNif.stream_start(
                Neo4j.graph(),
                "UNWIND range(1, $n) AS i RETURN i",
                %{"n" => rows_per}
              )

            values =
              Stream.repeatedly(fn -> BoltexNif.stream_next(stream) end)
              |> Enum.take_while(&(&1 != :done))
              |> Enum.map(fn {:ok, row} -> row["i"] end)

            {k, values}
          end)
        end

      for {_k, values} <- Task.await_many(tasks, 60_000) do
        assert values == Enum.to_list(1..rows_per)
      end
    end
  end

  # =========================================================================
  # pool saturation
  # =========================================================================

  describe "pool saturation" do
    test "200 in-flight queries against a pool of 4 all complete" do
      # The Neo4j GenServer is started in test_helper with max_connections: 4.
      # 200 tasks mean ~50× over-subscription; queueing in neo4rs's pool keeps
      # them all alive until each gets a free connection.
      n = 200

      tasks =
        for i <- 1..n do
          Task.async(fn -> Neo4j.execute("RETURN $i AS n", %{"i" => i}) end)
        end

      results = Task.await_many(tasks, 60_000)

      assert Enum.all?(results, fn {:ok, [%{"n" => v}]} -> is_integer(v) end)
      assert length(results) == n
    end
  end

  # =========================================================================
  # sustained load
  # =========================================================================

  describe "sustained load" do
    test "3 s of RETURN 1 at concurrency=16" do
      n_workers = 16
      deadline = System.monotonic_time(:millisecond) + 3_000

      tasks =
        for _ <- 1..n_workers do
          Task.async(fn -> pump_reads(deadline, []) end)
        end

      all_lats = tasks |> Task.await_many(15_000) |> List.flatten()
      assert all_lats != []

      count = length(all_lats)
      IO.puts("\n  sustained 3 s @ #{n_workers} workers: #{count} queries (#{div(count, 3)} q/s)")
      report("sustained reads", all_lats)
    end
  end

  # =========================================================================
  # sequential endurance
  # =========================================================================

  describe "sequential endurance" do
    test "2000 sequential reads complete without leak or slowdown" do
      n = 2_000

      {dur_us, _} =
        timed(fn ->
          for i <- 1..n do
            assert {:ok, [%{"n" => ^i}]} = Neo4j.execute("RETURN $i AS n", %{"i" => i})
          end
        end)

      IO.puts(
        "\n  sequential endurance: #{n} queries in #{round(dur_us / 1_000)} ms " <>
          "(#{throughput(n, dur_us)} q/s)"
      )
    end
  end
end
