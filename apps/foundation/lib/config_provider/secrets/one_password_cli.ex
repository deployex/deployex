defmodule Foundation.ConfigProvider.Secrets.OnePasswordCli do
  @moduledoc """
  Adapter implementation for retrieving secrets with the 1Password command line tool.

  The path is `vaults/<vault>/items/<item>`, and the secrets are the fields of that item,
  each one labelled with the name of the secret. See `Foundation.OnePassword.Cli`.
  """
  @behaviour Foundation.ConfigProvider.Secrets.Adapter

  alias Foundation.OnePassword

  @doc """
  secrets/3.

  Args:
    - The current config
    - path: The item that holds the secrets, e. g. vaults/production/items/deployex
    - opts is just the return value of init/1.
  """
  @impl true
  def secrets(_config, path, _opts) do
    case OnePassword.Cli.fetch(path) do
      {:ok, fields} -> fields
      {:error, reason} -> raise "Fail to retrieve secrets with reason #{inspect(reason)}"
    end
  end

  @impl true
  def application_env(path) do
    with {:ok, fields} <- OnePassword.Cli.fetch(path) do
      {:ok, OnePassword.to_env(fields)}
    end
  end
end
