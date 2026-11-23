defmodule Foundation.OnePassword.Cli do
  @moduledoc """
  Reads an item with the 1Password command line tool, `op`.

  `op` 2.30 or later has to be installed on the host and in the `PATH` of DeployEx. It signs
  in with what it finds in the environment of DeployEx: a service account token in
  `OP_SERVICE_ACCOUNT_TOKEN`, or a Connect server in `OP_CONNECT_HOST` and `OP_CONNECT_TOKEN`,
  which `op` prefers when both are set.
  """

  alias Foundation.OnePassword

  @doc """
  The fields of the item at `path`, as a map of label to value.

  An error names what could not be read, never a value of the item. What `op` itself reports
  goes to the standard error of DeployEx.
  """
  @spec fetch(String.t()) :: {:ok, OnePassword.fields()} | {:error, any()}
  def fetch(path) do
    with {:ok, vault, item} <- OnePassword.parse_path(path),
         :ok <- credentials(),
         {:ok, output} <- run(item_get_args(vault, item)) do
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

  # The output of a failed command is not returned, it could hold part of the item
  defp run(args) do
    case System.cmd("op", args) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, {:op_exit_status, status}}
    end
  rescue
    error in ErlangError ->
      if error.original == :enoent,
        do: {:error, :op_not_found},
        else: reraise(error, __STACKTRACE__)
  end
end
