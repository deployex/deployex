defmodule Deployer.Status.Db do
  @moduledoc """
  Discovers the database version a node's Ecto repos are connected to.

  DeployEx has no dependency on Ecto itself: every lookup runs over RPC on the
  monitored node, which already has Ecto (and the driver) loaded if it uses them.
  Repos are discovered through the `:ecto_repos` application env key, the same
  convention Ecto's own Mix tasks rely on, so nothing needs to be configured on
  the DeployEx side - including for an umbrella app, where the key can live
  under any of its child applications.
  """

  alias Foundation.Rpc

  @rpc_timeout 1_000

  @postgres_version_query "SHOW server_version"
  @mysql_version_query "SELECT VERSION()"

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
    do: run_query(node, repo, @postgres_version_query, "PostgreSQL")

  defp adapter_version(node, repo, Ecto.Adapters.MyXQL),
    do: run_query(node, repo, @mysql_version_query, "MySQL")

  defp adapter_version(_node, _repo, _adapter), do: {:ok, nil}

  defp run_query(node, repo, query, label) do
    case Rpc.call(node, Ecto.Adapters.SQL, :query, [repo, query, []], @rpc_timeout) do
      {:ok, %{rows: [[version]]}} -> {:ok, "#{label} #{version}"}
      _ -> {:ok, nil}
    end
  end
end
