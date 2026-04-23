defmodule PhoenixNeo4jWeb.PageController do
  use PhoenixNeo4jWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
