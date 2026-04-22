defmodule BoltexNif.Node do
  @moduledoc """
  A Neo4j node returned from a query.

  The `id` is the internal, transient Neo4j id. For stable identity across
  transactions prefer an application-level key on `properties` (or wait for
  Phase 3 when `element_id` is wired up via Bolt v5).
  """

  @enforce_keys [:id, :labels, :properties]
  defstruct [:id, :labels, :properties]

  @type t :: %__MODULE__{
          id: integer(),
          labels: [String.t()],
          properties: %{optional(String.t()) => term()}
        }
end
