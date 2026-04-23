defmodule BoltexNif.Relationship do
  @moduledoc """
  A Neo4j relationship (edge) with both endpoints bound.
  """

  @enforce_keys [:id, :start_node_id, :end_node_id, :type, :properties]
  defstruct [:id, :start_node_id, :end_node_id, :type, :properties]

  @type t :: %__MODULE__{
          id: integer(),
          start_node_id: integer(),
          end_node_id: integer(),
          type: String.t(),
          properties: %{optional(String.t()) => term()}
        }
end
