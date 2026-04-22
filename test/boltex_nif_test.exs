defmodule BoltexNifTest do
  use ExUnit.Case
  doctest BoltexNif

  test "greets the world" do
    assert BoltexNif.hello() == :world
  end
end
