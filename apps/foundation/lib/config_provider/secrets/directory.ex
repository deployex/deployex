defmodule Foundation.ConfigProvider.Secrets.Directory do
  @moduledoc """
  Adapter implementation for retrieving secrets from a directory of files.

  Each file in the directory is one secret: its name is the secret's name, and its content is
  the value, with one trailing newline removed if the file ends with one. A name that starts
  with `.` is skipped.

  This is how a Kubernetes Secret appears once mounted as a volume: one file per key, at the
  path named by the volume mount, with the `.` names of the mechanism Kubernetes uses to
  update the files without downtime left out. It is also how the Vault Agent injector and the
  Vault Secrets Store CSI driver place secrets on disk, and a Secret that the External Secrets
  Operator keeps in sync from AWS, GCP or Vault is still a Kubernetes Secret underneath, so it
  reaches a mounted volume the same way. This adapter does not call Kubernetes, Vault, or any
  other API: it only reads files, so all of them work with no code of their own.
  """
  @behaviour Foundation.ConfigProvider.Secrets.Adapter

  alias Foundation.ConfigProvider.Secrets.EnvName

  require Logger

  @doc """
  secrets/3.

  Args:
    - The current config
    - path: The directory that holds the secrets, e.g. /etc/deployex/secrets/deployex
    - opts is just the return value of init/1.
  """
  @impl true
  def secrets(_config, path, _opts) do
    case files(path) do
      {:ok, files} -> files
      {:error, reason} -> raise "Fail to retrieve secrets with reason #{inspect(reason)}"
    end
  end

  @impl true
  def application_env(path) do
    with {:ok, files} <- files(path), do: {:ok, to_env(files)}
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp files(path) do
    with {:ok, names} <- File.ls(path) do
      names
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, acc} ->
        case read(path, name) do
          {:ok, content} -> {:cont, {:ok, Map.put(acc, name, content)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp read(path, name) do
    case path |> Path.join(name) |> File.read() do
      {:ok, content} -> {:ok, trim_one_trailing_newline(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  # String.trim_trailing/2 removes every trailing match, not just one, so a file with two
  # trailing newlines would lose both. Only one is ever added by hand or by `kubectl create
  # secret generic --from-file`, so only one is removed
  defp trim_one_trailing_newline(content) do
    cond do
      String.ends_with?(content, "\r\n") -> binary_part(content, 0, byte_size(content) - 2)
      String.ends_with?(content, "\n") -> binary_part(content, 0, byte_size(content) - 1)
      true -> content
    end
  end

  defp to_env(files) do
    {env, skipped} =
      files
      |> Enum.sort()
      |> Enum.split_with(fn {name, _value} -> EnvName.valid?(name) end)

    if skipped != [] do
      Logger.warning(
        "Directory secrets not passed to the application, their names are not usable as " <>
          "environment variables: #{skipped |> Enum.map(&elem(&1, 0)) |> inspect()}"
      )
    end

    env
  end
end
