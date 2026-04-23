defmodule PhoenixNeo4jWeb.Neo4jControllerTest do
  use PhoenixNeo4jWeb.ConnCase, async: false

  alias PhoenixNeo4j.Neo4j

  @moduletag :live

  @cleanup """
  MATCH (n)
  WHERE any(l IN labels(n) WHERE l = 'Greeter' OR l STARTS WITH 'Test')
  DETACH DELETE n
  """

  setup do
    :ok = Neo4j.run(@cleanup)
    on_exit(fn -> if Process.whereis(Neo4j), do: Neo4j.run(@cleanup) end)
    :ok
  end

  # ---------- helpers ------------------------------------------------------

  defp init_csrf(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
  end

  # ---------- GET /neo4j ---------------------------------------------------

  describe "GET /neo4j" do
    test "renders the empty state with 0 greeters", %{conn: conn} do
      conn = get(conn, ~p"/neo4j")
      assert html_response(conn, 200) =~ "Neo4j demo"
      assert html_response(conn, 200) =~ "No greeters yet"
    end

    test "lists existing greeters", %{conn: conn} do
      :ok = Neo4j.run("CREATE (:Greeter {name:'Ada', inserted_at: timestamp()})")
      :ok = Neo4j.run("CREATE (:Greeter {name:'Grace', inserted_at: timestamp()})")

      html = conn |> get(~p"/neo4j") |> html_response(200)
      assert html =~ "Ada"
      assert html =~ "Grace"
      assert html =~ ">2<"
    end
  end

  # ---------- POST /neo4j/greeter -----------------------------------------

  describe "POST /neo4j/greeter" do
    test "creates a greeter, redirects, flashes success", %{conn: conn} do
      conn =
        conn
        |> init_csrf()
        |> post(~p"/neo4j/greeter", %{"greeter" => %{"name" => "Ada Lovelace"}})

      assert redirected_to(conn) == ~p"/neo4j"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Ada Lovelace"

      assert {:ok, [%{"c" => 1}]} =
               Neo4j.execute("MATCH (g:Greeter {name:'Ada Lovelace'}) RETURN count(g) AS c")
    end

    test "trims whitespace from the name", %{conn: conn} do
      conn =
        conn
        |> init_csrf()
        |> post(~p"/neo4j/greeter", %{"greeter" => %{"name" => "   Grace Hopper   "}})

      assert redirected_to(conn) == ~p"/neo4j"

      assert {:ok, [%{"c" => 1}]} =
               Neo4j.execute("MATCH (g:Greeter {name:'Grace Hopper'}) RETURN count(g) AS c")
    end

    test "rejects empty name with flash error", %{conn: conn} do
      conn =
        conn
        |> init_csrf()
        |> post(~p"/neo4j/greeter", %{"greeter" => %{"name" => ""}})

      assert redirected_to(conn) == ~p"/neo4j"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "empty"

      assert {:ok, [%{"c" => 0}]} =
               Neo4j.execute("MATCH (g:Greeter) RETURN count(g) AS c")
    end

    test "rejects whitespace-only name", %{conn: conn} do
      conn =
        conn
        |> init_csrf()
        |> post(~p"/neo4j/greeter", %{"greeter" => %{"name" => "   "}})

      assert redirected_to(conn) == ~p"/neo4j"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "empty"
    end

    test "preserves unicode in the stored name", %{conn: conn} do
      conn
      |> init_csrf()
      |> post(~p"/neo4j/greeter", %{"greeter" => %{"name" => "漢字 🚀 ñ"}})

      assert {:ok, [%{"c" => 1}]} =
               Neo4j.execute("MATCH (g:Greeter {name:'漢字 🚀 ñ'}) RETURN count(g) AS c")
    end
  end

  # ---------- DELETE /neo4j/greeter ---------------------------------------

  describe "DELETE /neo4j/greeter" do
    test "wipes every greeter", %{conn: conn} do
      :ok = Neo4j.run("UNWIND range(1,5) AS i CREATE (:Greeter {name: toString(i)})")

      conn =
        conn
        |> init_csrf()
        |> delete(~p"/neo4j/greeter")

      assert redirected_to(conn) == ~p"/neo4j"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "removed"

      assert {:ok, [%{"c" => 0}]} =
               Neo4j.execute("MATCH (g:Greeter) RETURN count(g) AS c")
    end

    test "is a no-op when there are no greeters", %{conn: conn} do
      conn =
        conn
        |> init_csrf()
        |> delete(~p"/neo4j/greeter")

      assert redirected_to(conn) == ~p"/neo4j"
    end
  end

  # ---------- smoke for the root page -------------------------------------

  describe "GET /" do
    @describetag :live_optional

    test "renders the Phoenix welcome page", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Phoenix Framework"
    end
  end
end
