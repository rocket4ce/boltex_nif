defmodule BoltexNif.Neo4jError do
  @moduledoc """
  A server-side Cypher/transaction error reported by Neo4j.

  `kind` is a classification atom derived from the Neo4j error code — handy
  for retry decisions without parsing the `code` string yourself.
  """

  @enforce_keys [:code, :message, :kind]
  defstruct [:code, :message, :kind]

  @type kind ::
          :authentication
          | :authorization_expired
          | :token_expired
          | :other_security
          | :session_expired
          | :fatal_discovery
          | :transaction_terminated
          | :protocol_violation
          | :client_other
          | :client_unknown
          | :transient
          | :database
          | :unknown

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          kind: kind()
        }

  @retryable_kinds [:transient, :session_expired, :authorization_expired]

  @doc """
  Returns `true` if `neo4rs` considers this error retryable (either transient
  or requiring a reconnect / token refresh).
  """
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{kind: kind}), do: kind in @retryable_kinds
end
