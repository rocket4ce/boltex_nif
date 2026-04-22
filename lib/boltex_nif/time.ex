defmodule BoltexNif.Time do
  @moduledoc """
  A time-of-day with a fixed UTC offset (Bolt `Time`).

  Elixir's built-in `%Time{}` has no timezone component, so `Time` is paired
  with `offset_seconds` here. Use `%Time{}` directly (via `BoltexNif` params)
  for the timezone-less Bolt `LocalTime` type.
  """

  @enforce_keys [:time, :offset_seconds]
  defstruct [:time, :offset_seconds]

  @type t :: %__MODULE__{
          time: Time.t(),
          offset_seconds: integer()
        }
end
