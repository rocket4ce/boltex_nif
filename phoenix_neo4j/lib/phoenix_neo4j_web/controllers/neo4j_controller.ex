defmodule PhoenixNeo4jWeb.Neo4jController do
  use PhoenixNeo4jWeb, :controller

  alias PhoenixNeo4j.Neo4j

  @limit 25

  def index(conn, _params) do
    with {:ok, [%{"count" => count}]} <-
           Neo4j.execute("MATCH (g:Greeter) RETURN count(g) AS count"),
         {:ok, rows} <-
           Neo4j.execute(
             "MATCH (g:Greeter) RETURN g ORDER BY g.inserted_at DESC LIMIT $limit",
             %{"limit" => @limit}
           ) do
      greeters = Enum.map(rows, & &1["g"])
      render(conn, :index, count: count, greeters: greeters, error: nil)
    else
      {:error, reason} ->
        render(conn, :index,
          count: 0,
          greeters: [],
          error: "Neo4j error: #{inspect(reason)}"
        )
    end
  end

  def create(conn, %{"greeter" => %{"name" => name}}) do
    name = String.trim(name || "")

    cond do
      name == "" ->
        conn
        |> put_flash(:error, "Name can't be empty.")
        |> redirect(to: ~p"/neo4j")

      true ->
        case Neo4j.run(
               "CREATE (:Greeter {name: $name, inserted_at: timestamp()})",
               %{"name" => name}
             ) do
          :ok ->
            conn
            |> put_flash(:info, "Saved “#{name}”.")
            |> redirect(to: ~p"/neo4j")

          {:error, reason} ->
            conn
            |> put_flash(:error, "Save failed: #{inspect(reason)}")
            |> redirect(to: ~p"/neo4j")
        end
    end
  end

  def delete_all(conn, _params) do
    case Neo4j.run("MATCH (g:Greeter) DETACH DELETE g") do
      :ok ->
        conn
        |> put_flash(:info, "All greeters removed.")
        |> redirect(to: ~p"/neo4j")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Delete failed: #{inspect(reason)}")
        |> redirect(to: ~p"/neo4j")
    end
  end
end
