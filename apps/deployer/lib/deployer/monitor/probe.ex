defmodule Deployer.Monitor.Probe do
  @moduledoc """
  Checks whether a started application satisfies its readiness configuration.

  The `:otp` check reads the boot status of the node, which needs nothing from the application.
  A node that is not up yet, or does not answer in time, is not ready.

  A release reports `{:started, :started}` only after its boot script has started every
  application, so that is what it must answer.

  A Gleam application boots from `-eval`, and `gleam@@main:run/1` blocks there until the
  application ends, so a healthy node answers `{:starting, :started}` for its whole life. The check
  then only says that the node is up and answering, not that `main` finished its own setup.
  """

  alias Foundation.Rpc
  alias Foundation.Yaml.Readiness

  @rpc_timeout 1_000

  ### ==========================================================================
  ### Public APIs
  ### ==========================================================================

  @doc """
  Return true when the application running on the node is ready.
  """
  @spec ready?(readiness :: Readiness.t(), node :: node(), language :: String.t() | nil) ::
          boolean()
  def ready?(%Readiness{type: :timeout}, _node, _language), do: true

  def ready?(%Readiness{type: :otp}, node, language),
    do: booted?(language, Rpc.call(node, :init, :get_status, [], @rpc_timeout))

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================
  defp booted?(_language, {:started, :started}), do: true
  defp booted?("gleam", {:starting, :started}), do: true
  defp booted?(_language, _status), do: false
end
