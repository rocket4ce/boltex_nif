defmodule BoltexNif.DateTime do
  @moduledoc """
  A `NaiveDateTime` paired with a fixed UTC offset — mirrors Bolt's `DateTime`
  (not `DateTimeZoneId`).

  Elixir's stdlib `%DateTime{}` requires a full time-zone database to round-trip
  arbitrary offsets, so we keep the naive value + offset explicit.
  """

  @enforce_keys [:naive, :offset_seconds]
  defstruct [:naive, :offset_seconds]

  @type t :: %__MODULE__{
          naive: NaiveDateTime.t(),
          offset_seconds: integer()
        }
end
