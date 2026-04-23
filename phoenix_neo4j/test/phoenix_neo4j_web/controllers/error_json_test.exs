defmodule PhoenixNeo4jWeb.ErrorJSONTest do
  use PhoenixNeo4jWeb.ConnCase, async: true

  test "renders 404" do
    assert PhoenixNeo4jWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert PhoenixNeo4jWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
