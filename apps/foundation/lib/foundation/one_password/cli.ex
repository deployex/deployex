defmodule Foundation.OnePassword.Cli do
  @moduledoc """
  Reads an item with the 1Password command line tool, `op`.

  `op` 2.30 or later has to be installed on the host and in the `PATH` of DeployEx. It signs
  in with what it finds in the environment of DeployEx: a service account token in
  `OP_SERVICE_ACCOUNT_TOKEN`, or a Connect server in `OP_CONNECT_HOST` and `OP_CONNECT_TOKEN`,
  which `op` prefers when both are set.
  """

  alias Foundation.OnePassword

  @timeout_ms 30_000

  @doc """
  The fields of the item at `path`, as a map of label to value.

  An error names what could not be read, never a value of the item. What `op` itself reports
  goes to the standard error of DeployEx.

  `op` is given `timeout_ms` to answer, 30 seconds unless set in `opts`, and is killed when it
  does not: the caller is the monitor of an application, which answers nothing else meanwhile.
  """
  @spec fetch(String.t(), Keyword.t()) :: {:ok, OnePassword.fields()} | {:error, any()}
  def fetch(path, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @timeout_ms)

    with {:ok, vault, item} <- OnePassword.parse_path(path),
         :ok <- credentials(),
         {:ok, output} <- run(item_get_args(vault, item), timeout_ms) do
      case Jason.decode(output) do
        {:ok, %{"fields" => fields}} -> {:ok, OnePassword.fields_to_map(fields)}
        {:ok, _item_without_fields} -> {:ok, %{}}
        {:error, _reason} -> {:error, :invalid_json}
      end
    end
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # A service account has to name the vault. --reveal keeps concealed values in the output,
  # and is what makes 2.30 the oldest release that works
  defp item_get_args(vault, item),
    do: ["item", "get", item, "--vault", vault, "--format", "json", "--reveal"]

  defp credentials do
    service_account? = set?("OP_SERVICE_ACCOUNT_TOKEN")
    connect? = set?("OP_CONNECT_HOST") and set?("OP_CONNECT_TOKEN")

    if service_account? or connect? do
      :ok
    else
      {:error, {:missing_env, ["OP_SERVICE_ACCOUNT_TOKEN"]}}
    end
  end

  defp set?(name), do: System.get_env(name) not in [nil, ""]

  # A port and not System.cmd/3, which waits for as long as the command runs. Not
  # Host.Commander either: the host application depends on this one, and the config provider
  # reads the secrets of DeployEx before any application, erlexec included, is started
  defp run(args, timeout_ms) do
    case System.find_executable("op") do
      nil ->
        {:error, :op_not_found}

      op ->
        port = Port.open({:spawn_executable, op}, [:binary, :exit_status, :hide, args: args])
        collect(port, [], System.monotonic_time(:millisecond) + timeout_ms, timeout_ms)
    end
  end

  # The output of a failed command is not returned, it could hold part of the item
  defp collect(port, output, deadline, timeout_ms) do
    receive do
      {^port, {:data, data}} -> collect(port, [output, data], deadline, timeout_ms)
      {^port, {:exit_status, 0}} -> {:ok, IO.iodata_to_binary(output)}
      {^port, {:exit_status, status}} -> {:error, {:op_exit_status, status}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        kill(port)
        {:error, {:op_timeout, timeout_ms}}
    end
  end

  # Closing the port only closes the pipes of the command, which would keep running
  defp kill(port) do
    os_pid = port |> Port.info(:os_pid) |> elem(1)
    Port.close(port)
    _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end
end
