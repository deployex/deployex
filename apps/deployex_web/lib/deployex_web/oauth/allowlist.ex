defmodule DeployexWeb.OAuth.Allowlist do
  @moduledoc """
  Decides whether an authenticated email may access DeployEx, and with which role.

  Deny by default: an empty or missing allowlist denies everyone. Access is
  granted only when the email matches a configured email or domain. Matching
  is case-insensitive.

  `emails` and `domains` sign in as admins. `read_only_emails` and
  `read_only_domains` sign in with read-only access, see `DeployexWeb.Authorization`.
  """

  @type config :: %{
          optional(:emails) => [String.t()],
          optional(:domains) => [String.t()],
          optional(:read_only_emails) => [String.t()],
          optional(:read_only_domains) => [String.t()]
        }

  @spec check(String.t(), config() | nil) :: :ok | :denied
  def check(email, config) do
    if role(email, config) == :denied, do: :denied, else: :ok
  end

  @doc """
  The role an authenticated email signs in with: `:admin` when it matches `emails` or
  `domains`, `:read_only` when it matches `read_only_emails` or `read_only_domains`, and
  `:denied` otherwise. An email that matches both is an admin.
  """
  @spec role(String.t(), config() | nil) :: :admin | :read_only | :denied
  def role(_email, nil), do: :denied

  def role(email, config) do
    cond do
      listed?(email, config, :emails, :domains) -> :admin
      listed?(email, config, :read_only_emails, :read_only_domains) -> :read_only
      true -> :denied
    end
  end

  defp listed?(email, config, emails_key, domains_key) do
    emails = config |> Map.get(emails_key, []) |> Enum.map(&String.downcase/1)
    domains = config |> Map.get(domains_key, []) |> Enum.map(&String.downcase/1)
    email = String.downcase(email)

    email in emails or (email |> String.split("@") |> List.last()) in domains
  end
end
