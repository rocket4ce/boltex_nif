defmodule BoltexNif.Path do
  @moduledoc """
  An alternating sequence of nodes and relationships returned by Neo4j.

  `indices` follows the Bolt spec: a flat list alternating between a
  relationship index (into `relationships`, negative for reverse traversal)
  and the node index (into `nodes`) that the relationship ends on.
  """

  @enforce_keys [:nodes, :relationships, :indices]
  defstruct [:nodes, :relationships, :indices]

  @type t :: %__MODULE__{
          nodes: [BoltexNif.Node.t()],
          relationships: [BoltexNif.UnboundRelationship.t()],
          indices: [integer()]
        }
end
