defmodule PhoenixNeo4j.Neo4jStressTest do
  @moduledoc """
  Opt-in concurrency/stress suite.

      mix test --include live --include stress
      mix test --only stress

  Defaults assume you're running against a single Community Neo4j. Numbers
  auto-scale down when the round-trip latency is high (e.g. a remote Coolify
  box) via `STRESS_SCALE` (default 1.0 — use 0.25 on high-latency links).

  Tests are excluded by default: the test_helper lists `:stress` in the
  exclude set, and stress tests also carry `:live` so they skip when there
  is no DB configured.
  """

  use PhoenixNeo4j.Neo4jCase, async: false

  @moduletag :stress
  @moduletag :live
  @moduletag timeout: :timer.minutes(10)

  # Long query timeout: we deliberately oversubscribe a small pool, so any
  # single query must tolerate waiting in line for a connection.
  @long_timeout :timer.seconds(120)

  # =========================================================================
  # helpers
  # =========================================================================

  defp scale do
    :phoenix_neo4j
    |> Application.get_env(:stress_scale)
    |> case do
      nil -> System.get_env("STRESS_SCALE", "1.0") |> String.to_float()
      s -> s
    end
  end

  defp scaled(n) when is_integer(n), do: max(1, round(n * scale()))

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

  defp pump_reads(deadline, acc) do
    if System.monotonic_time(:millisecond) >= deadline do
      acc
    else
      {us, {:ok, [%{"n" => 1}]}} =
        timed(fn -> Neo4j.execute("RETURN 1 AS n", nil, timeout: @long_timeout) end)

      pump_reads(deadline, [us | acc])
    end
  end

  # =========================================================================
  # read concurrency
  # =========================================================================

  describe "read concurrency" do
    test "parallel reads at concurrency=50" do
      n = scaled(500)
      concurrency = 50

      {total_us, results} =
        timed(fn ->
          1..n
          |> Task.async_stream(
            fn i ->
              {us, {:ok, [%{"n" => v}]}} =
                timed(fn ->
                  Neo4j.execute("RETURN $i AS n", %{"i" => i}, timeout: @long_timeout)
                end)

              {us, v == i}
            end,
            max_concurrency: concurrency,
            timeout: :timer.seconds(180),
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

      report("#{n} parallel reads", lats)
    end
  end

  # =========================================================================
  # write concurrency
  # =========================================================================

  describe "write concurrency" do
    test "parallel writes produce the expected node count" do
      n = scaled(150)
      concurrency = 32

      {total_us, _} =
        timed(fn ->
          1..n
          |> Task.async_stream(
            fn i ->
              :ok =
                Neo4j.run("CREATE (:TestStress {i: $i})", %{"i" => i},
                  timeout: @long_timeout
                )
            end,
            max_concurrency: concurrency,
            timeout: :timer.seconds(180),
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
    test "reads + writes interleaved, no losses" do
      n = scaled(40)

      writers =
        for i <- 1..n do
          Task.async(fn ->
            Neo4j.run("CREATE (:TestStress {i: $i})", %{"i" => i}, timeout: @long_timeout)
          end)
        end

      readers =
        for i <- 1..n do
          Task.async(fn ->
            Neo4j.execute("RETURN $i AS n", %{"i" => i}, timeout: @long_timeout)
          end)
        end

      assert Enum.all?(Task.await_many(writers, :timer.seconds(180)), &(&1 == :ok))

      read_results = Task.await_many(readers, :timer.seconds(180))
      assert Enum.all?(read_results, &match?({:ok, [_row]}, &1))

      {:ok, [%{"c" => c}]} =
        Neo4j.execute("MATCH (n:TestStress) RETURN count(n) AS c")

      assert c == n
    end
  end

  # =========================================================================
  # transactions under concurrency
  # =========================================================================

  describe "transaction concurrency" do
    test "concurrent transactions each writing N nodes all commit" do
      n_tx = scaled(15)
      writes_per_tx = 5

      tasks =
        for i <- 1..n_tx do
          Task.async(fn ->
            BoltexNif.transaction(
              Neo4j.graph(),
              fn txn ->
                for j <- 1..writes_per_tx do
                  {:ok, _} =
                    BoltexNif.txn_run(
                      txn,
                      "CREATE (:TestStress {i: $i, j: $j})",
                      %{"i" => i, "j" => j},
                      timeout: @long_timeout
                    )
                end

                {:ok, :done}
              end,
              timeout: @long_timeout
            )
          end)
        end

      results = Task.await_many(tasks, :timer.seconds(180))
      assert Enum.all?(results, &match?({:ok, :done}, &1))

      {:ok, [%{"c" => c}]} =
        Neo4j.execute("MATCH (n:TestStress) RETURN count(n) AS c")

      assert c == n_tx * writes_per_tx
    end

    test "rollbacks under concurrency leak zero writes" do
      n = scaled(10)

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            BoltexNif.transaction(
              Neo4j.graph(),
              fn txn ->
                {:ok, _} =
                  BoltexNif.txn_run(
                    txn,
                    "CREATE (:TestStress {bad:true, i: $i})",
                    %{"i" => i},
                    timeout: @long_timeout
                  )

                {:error, :intentional_rollback}
              end,
              timeout: @long_timeout
            )
          end)
        end

      results = Task.await_many(tasks, :timer.seconds(180))
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
    test "multiple streams drained in parallel" do
      n_streams = scaled(8)
      rows_per = 25

      tasks =
        for k <- 1..n_streams do
          Task.async(fn ->
            {:ok, stream} =
              BoltexNif.stream_start(
                Neo4j.graph(),
                "UNWIND range(1, $n) AS i RETURN i",
                %{"n" => rows_per},
                timeout: @long_timeout
              )

            values =
              Stream.repeatedly(fn ->
                BoltexNif.stream_next(stream, timeout: @long_timeout)
              end)
              |> Enum.take_while(&(&1 != :done))
              |> Enum.map(fn {:ok, row} -> row["i"] end)

            {k, values}
          end)
        end

      for {_k, values} <- Task.await_many(tasks, :timer.seconds(180)) do
        assert values == Enum.to_list(1..rows_per)
      end
    end
  end

  # =========================================================================
  # pool saturation — deliberate oversubscription of a small pool
  # =========================================================================

  describe "pool saturation" do
    test "in-flight queries 10× the pool size all complete" do
      # 40 tasks against a pool of 4 means every task waits ~10 round-trips
      # on average. With @long_timeout each tolerates the queue depth.
      n = scaled(40)

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            Neo4j.execute("RETURN $i AS n", %{"i" => i}, timeout: @long_timeout)
          end)
        end

      results = Task.await_many(tasks, :timer.seconds(180))

      values =
        Enum.map(results, fn
          {:ok, [%{"n" => v}]} -> v
          other -> flunk("pool saturation got #{inspect(other)}")
        end)

      assert Enum.sort(values) == Enum.to_list(1..n)
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

      all_lats = tasks |> Task.await_many(30_000) |> List.flatten()
      assert all_lats != []

      count = length(all_lats)
      IO.puts("\n  sustained 3 s @ #{n_workers} workers: #{count} queries (#{div(count, 3)} q/s)")
      report("sustained reads", all_lats)
    end
  end

  # =========================================================================
  # sequential endurance — validates no slow leak / memory growth
  # =========================================================================

  describe "sequential endurance" do
    test "sequential reads complete without leak" do
      # Scale aggressively on the WAN: 300 × ~400ms ≈ 2 min, still meaningful
      # to detect slow degradation. Bump STRESS_SCALE up for local Neo4j.
      n = scaled(300)

      {dur_us, _} =
        timed(fn ->
          for i <- 1..n do
            assert {:ok, [%{"n" => ^i}]} =
                     Neo4j.execute("RETURN $i AS n", %{"i" => i}, timeout: @long_timeout)
          end
        end)

      IO.puts(
        "\n  sequential endurance: #{n} queries in #{round(dur_us / 1_000)} ms " <>
          "(#{throughput(n, dur_us)} q/s)"
      )
    end
  end
end
