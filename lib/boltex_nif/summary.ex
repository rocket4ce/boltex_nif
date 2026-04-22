defmodule BoltexNif.Summary do
  @moduledoc """
  Metadata returned alongside a query run — timing, counters, notifications,
  and (under Bolt v5) the bookmark identifying the committed state.
  """

  defmodule Counters do
    @moduledoc "Database write statistics produced by a query."

    @fields [
      :nodes_created,
      :nodes_deleted,
      :relationships_created,
      :relationships_deleted,
      :properties_set,
      :labels_added,
      :labels_removed,
      :indexes_added,
      :indexes_removed,
      :constraints_added,
      :constraints_removed,
      :system_updates
    ]
    @enforce_keys @fields
    defstruct @fields

    @type t :: %__MODULE__{
            nodes_created: non_neg_integer(),
            nodes_deleted: non_neg_integer(),
            relationships_created: non_neg_integer(),
            relationships_deleted: non_neg_integer(),
            properties_set: non_neg_integer(),
            labels_added: non_neg_integer(),
            labels_removed: non_neg_integer(),
            indexes_added: non_neg_integer(),
            indexes_removed: non_neg_integer(),
            constraints_added: non_neg_integer(),
            constraints_removed: non_neg_integer(),
            system_updates: non_neg_integer()
          }
  end

  @enforce_keys [
    :bookmark,
    :available_after_ms,
    :consumed_after_ms,
    :query_type,
    :db,
    :stats,
    :notifications
  ]
  defstruct [
    :bookmark,
    :available_after_ms,
    :consumed_after_ms,
    :query_type,
    :db,
    :stats,
    :notifications
  ]

  @type query_type :: String.t()
  @type t :: %__MODULE__{
          bookmark: String.t() | nil,
          available_after_ms: non_neg_integer() | nil,
          consumed_after_ms: non_neg_integer() | nil,
          query_type: query_type(),
          db: String.t() | nil,
          stats: Counters.t(),
          notifications: [BoltexNif.Notification.t()]
        }
end
