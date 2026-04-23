defmodule BoltexNif.Notification do
  @moduledoc "A Cypher notification emitted by the server (warnings, hints, etc.)."

  defmodule InputPosition do
    @moduledoc "Source position inside the Cypher query a notification refers to."

    @enforce_keys [:offset, :line, :column]
    defstruct [:offset, :line, :column]

    @type t :: %__MODULE__{
            offset: integer(),
            line: integer(),
            column: integer()
          }
  end

  @enforce_keys [:code, :title, :description, :severity, :category, :position]
  defstruct [:code, :title, :description, :severity, :category, :position]

  @type t :: %__MODULE__{
          code: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          severity: String.t() | nil,
          category: String.t() | nil,
          position: InputPosition.t() | nil
        }
end
