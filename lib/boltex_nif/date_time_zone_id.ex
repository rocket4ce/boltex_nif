defmodule BoltexNif.DateTimeZoneId do
  @moduledoc """
  A `NaiveDateTime` paired with an IANA time-zone identifier (e.g.
  `"Europe/Paris"`) — mirrors Bolt's `DateTimeZoneId`.
  """

  @enforce_keys [:naive, :tz_id]
  defstruct [:naive, :tz_id]

  @type t :: %__MODULE__{
          naive: NaiveDateTime.t(),
          tz_id: String.t()
        }
end
