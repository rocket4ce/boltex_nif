defmodule BoltexNif.Point do
  @moduledoc """
  A spatial point. `z` is `nil` for 2D points; otherwise a float for 3D points.
  `srid` is the [Spatial Reference System Identifier](https://en.wikipedia.org/wiki/Spatial_reference_system#Identifier).
  """

  @enforce_keys [:srid, :x, :y]
  defstruct [:srid, :x, :y, :z]

  @type t :: %__MODULE__{
          srid: integer(),
          x: float(),
          y: float(),
          z: float() | nil
        }
end
