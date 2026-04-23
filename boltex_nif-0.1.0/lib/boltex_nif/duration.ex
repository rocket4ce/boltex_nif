defmodule BoltexNif.Duration do
  @moduledoc """
  A Neo4j temporal duration.

  Bolt preserves the four components independently (months and days can't be
  folded into seconds without a reference date/timezone), so this struct keeps
  them separate.
  """

  @enforce_keys [:months, :days, :seconds, :nanoseconds]
  defstruct [:months, :days, :seconds, :nanoseconds]

  @type t :: %__MODULE__{
          months: integer(),
          days: integer(),
          seconds: integer(),
          nanoseconds: integer()
        }
end
