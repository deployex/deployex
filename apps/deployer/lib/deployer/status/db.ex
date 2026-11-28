defmodule Deployer.Status.Db do
  @moduledoc """
  Discovers the database version a node's Ecto repos are connected to.

  DeployEx has no dependency on Ecto itself: every lookup runs over RPC on the
  monitored node, which already has Ecto (and the driver) loaded if it uses them.
  Repos are discovered through the `:ecto_repos` application env key, the same
  convention Ecto's own Mix tasks rely on, so nothing needs to be configured on
  the DeployEx side - including for an umbrella app, where the key can live
  under any of its child applications.

  CockroachDB speaks the Postgres wire protocol and uses the same
  `Ecto.Adapters.Postgres` adapter as Postgres itself, so the adapter module
  alone cannot tell them apart. `SHOW server_version` makes it worse: CockroachDB
  reports a Postgres version it merely emulates there, not its own. `SELECT
  version()` is the one that self-identifies, so both read it and the result is
  parsed to tell which database actually answered.
  """

  alias Foundation.Rpc

  @rpc_timeout 1_000

  @postgres_family_version_query "SELECT version()"
  @mysql_version_query "SELECT VERSION()"

  @crdb_version_regex ~r/CockroachDB.*?v([\d.]+)/
  @postgres_version_regex ~r/^PostgreSQL ([\d.]+)/

  ### ==========================================================================
  ### Public APIs
  ### ==========================================================================

  @doc """
  Return "<database> <version>" for the first Ecto repo found running on the
  node, or nil when none is configured, its adapter isn't recognized, or the
  node is unreachable.
  """
  @spec version(node :: node()) :: {:ok, String.t() | nil} | {:error, nil}
  def version(node) do
    with {:ok, repos} <- ecto_repos(node) do
      repos
      |> Enum.find_value({:ok, nil}, fn repo ->
        case repo_version(node, repo) do
          {:ok, nil} -> nil
          result -> result
        end
      end)
    end
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp ecto_repos(node) do
    case Rpc.call(node, :application, :which_applications, [], @rpc_timeout) do
      {:badrpc, _} ->
        {:error, nil}

      apps when is_list(apps) ->
        repos =
          apps
          |> Enum.flat_map(fn {app, _description, _vsn} -> app_ecto_repos(node, app) end)
          |> Enum.uniq()

        {:ok, repos}

      _ ->
        {:ok, []}
    end
  end

  defp app_ecto_repos(node, app) do
    case Rpc.call(node, Application, :get_env, [app, :ecto_repos, []], @rpc_timeout) do
      repos when is_list(repos) -> repos
      _ -> []
    end
  end

  defp repo_version(node, repo) do
    case Rpc.call(node, repo, :__adapter__, [], @rpc_timeout) do
      {:badrpc, _} -> {:ok, nil}
      adapter -> adapter_version(node, repo, adapter)
    end
  end

  defp adapter_version(node, repo, Ecto.Adapters.Postgres),
    do: run_query(node, repo, @postgres_family_version_query, &parse_postgres_family/1)

  defp adapter_version(node, repo, Ecto.Adapters.MyXQL),
    do: run_query(node, repo, @mysql_version_query, &"MySQL #{&1}")

  defp adapter_version(_node, _repo, _adapter), do: {:ok, nil}

  defp run_query(node, repo, query, format) do
    case Rpc.call(node, Ecto.Adapters.SQL, :query, [repo, query, []], @rpc_timeout) do
      {:ok, %{rows: [[version]]}} -> {:ok, format.(version)}
      _ -> {:ok, nil}
    end
  end

  # CockroachDB identifies itself in the free-form "SELECT version()" string;
  # anything else that answers through the Postgres adapter is treated as Postgres itself.
  defp parse_postgres_family(version_string) do
    case Regex.run(@crdb_version_regex, version_string) do
      [_, version] -> "CockroachDB #{version}"
      nil -> parse_postgres(version_string)
    end
  end

  defp parse_postgres(version_string) do
    case Regex.run(@postgres_version_regex, version_string) do
      [_, version] -> "PostgreSQL #{version}"
      nil -> version_string
    end
  end
end
