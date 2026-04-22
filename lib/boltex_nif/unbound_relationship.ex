defmodule BoltexNif.UnboundRelationship do
  @moduledoc """
  A relationship detached from its start/end nodes — used inside `BoltexNif.Path`.
  """

  @enforce_keys [:id, :type, :properties]
  defstruct [:id, :type, :properties]

  @type t :: %__MODULE__{
          id: integer(),
          type: String.t(),
          properties: %{optional(String.t()) => term()}
        }
end
