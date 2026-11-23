defmodule Foundation.ConfigProvider.Secrets.Adapter do
  @moduledoc """
  Behaviour that defines the secret retrieval
  """

  @callback secrets([Keyword.t()], String.t(), [Keyword.t()]) :: map()

  @doc """
  The secrets of a monitored application at `path`, as the environment variables it is
  started with. Only the adapters that can be set on an application implement it.
  """
  @callback application_env(path :: String.t()) ::
              {:ok, [{String.t(), String.t()}]} | {:error, any()}

  @optional_callbacks application_env: 1
end
