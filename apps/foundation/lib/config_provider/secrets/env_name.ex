defmodule Foundation.ConfigProvider.Secrets.EnvName do
  @moduledoc """
  What names a secrets adapter may pass to a monitored application as an environment variable.

  A name must be a valid environment variable name, and must not start with `RELEASE_` or
  `DEPLOYEX_`: the run script of a monitored application removes every variable with one of
  those prefixes before it starts the application, so a secret under such a name would never
  reach it.
  """

  @reserved_prefixes ["RELEASE_", "DEPLOYEX_"]

  @doc """
  Whether `name` is usable as an environment variable DeployEx will pass through.

  ## Examples

      iex> Foundation.ConfigProvider.Secrets.EnvName.valid?("DATABASE_URL")
      true
      iex> Foundation.ConfigProvider.Secrets.EnvName.valid?("not-a-valid-name")
      false
      iex> Foundation.ConfigProvider.Secrets.EnvName.valid?("RELEASE_COOKIE")
      false
      iex> Foundation.ConfigProvider.Secrets.EnvName.valid?("DEPLOYEX_SECRET_KEY_BASE")
      false
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(name) do
    Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name) and
      not String.starts_with?(name, @reserved_prefixes)
  end
end
