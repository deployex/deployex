defmodule Deployer.HotUpgrade.Relup do
  @moduledoc """
  The relup of a hot upgrade, kept with the version history so what the node ran can be
  seen after the release directories are gone.

  Only the upgrade is kept. A relup also describes the way back, which DeployEx never applies.
  """

  alias Deployer.HotUpgrade.Execute
  alias Foundation.Catalog

  require Logger

  @typedoc """
  What the upgrade does, counted from its instructions.

    * `applications` - the applications whose code is replaced, with their new version
    * `modules` - the modules that are loaded from those applications
    * `updated` - the modules whose processes are suspended and given a `code_change`
    * `applies` - the functions the upgrade calls, as `Module.function/arity`
    * `runtime_config` - whether DeployEx applies the runtime configuration in it, which is
      also what carries the `config_change` marker
    * `restart_emulator` - whether the upgrade restarts the VM
    * `instructions` - the number of instructions in the script
  """
  @type summary :: %{
          applications: [{String.t(), String.t()}],
          modules: non_neg_integer(),
          updated: [String.t()],
          removed: [String.t()],
          applies: [String.t()],
          runtime_config: boolean(),
          restart_emulator: boolean(),
          instructions: non_neg_integer()
        }

  @type t :: %{
          from_version: String.t(),
          to_version: String.t(),
          summary: summary(),
          text: String.t(),
          inserted_at: NaiveDateTime.t()
        }

  @doc """
  Keeps the relup that is about to be installed, as it is on disk at that moment, with the
  instruction DeployEx added to it.

  It never fails the upgrade: a relup that cannot be read or kept is logged and skipped.
  """
  @spec save(Execute.t()) :: :ok
  def save(%Execute{name: name, current_path: current_path} = data)
      when is_binary(name) and is_binary(current_path) do
    from_version = to_string(data.from_version)
    to_version = to_string(data.to_version)
    relup_path = "#{current_path}/releases/#{to_version}/relup"

    with {:ok, [{_to_vsn, up, _down}]} <- :file.consult(relup_path),
         {:ok, script} <- script_from(up, from_version),
         :ok <-
           Catalog.add_relup(name, %{
             from_version: from_version,
             to_version: to_version,
             summary: summary(script),
             text: format(to_version, from_version, script),
             inserted_at: NaiveDateTime.utc_now()
           }) do
      :ok
    else
      reason ->
        Logger.warning(
          "Could not keep the relup of #{name} #{from_version} -> #{to_version}, " <>
            "reason: #{inspect(reason)}"
        )

        :ok
    end
  end

  def save(_data), do: :ok

  @doc """
  Counts what the instructions of an upgrade script do.

  ## Examples

      iex> Deployer.HotUpgrade.Relup.summary([
      ...>   {:load_object_code, {:myapp, ~c"1.1.0", [MyApp.Worker, MyApp.Web]}},
      ...>   :point_of_no_return,
      ...>   {:suspend, [MyApp.Worker]},
      ...>   {:load, {MyApp.Worker, :brutal_purge, :brutal_purge}},
      ...>   {:code_change, :up, [{MyApp.Worker, []}]},
      ...>   {:resume, [MyApp.Worker]},
      ...>   {:load, {MyApp.Web, :brutal_purge, :brutal_purge}},
      ...>   {:apply, {MyApp.Release, :after_upgrade, [:now]}}
      ...> ])
      %{
        applications: [{"myapp", "1.1.0"}],
        modules: 2,
        updated: ["MyApp.Worker"],
        removed: [],
        applies: ["MyApp.Release.after_upgrade/1"],
        runtime_config: false,
        restart_emulator: false,
        instructions: 8
      }
  """
  @spec summary(list()) :: summary()
  def summary(script) when is_list(script) do
    empty = %{
      applications: [],
      modules: 0,
      updated: [],
      removed: [],
      applies: [],
      runtime_config: false,
      restart_emulator: false,
      instructions: length(script)
    }

    script
    |> Enum.reduce(empty, &count/2)
    |> Map.update!(:applications, &Enum.reverse/1)
    |> Map.update!(:updated, &(&1 |> Enum.reverse() |> Enum.uniq()))
    |> Map.update!(:removed, &(&1 |> Enum.reverse() |> Enum.uniq()))
    |> Map.update!(:applies, &Enum.reverse/1)
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp count({:load_object_code, {app, vsn, modules}}, acc) do
    %{
      acc
      | applications: [{to_string(app), to_string(vsn)} | acc.applications],
        modules: acc.modules + length(modules)
    }
  end

  defp count({:code_change, _mode, modules}, acc),
    do: %{acc | updated: Enum.reduce(modules, acc.updated, &[module_name(elem(&1, 0)) | &2])}

  defp count({:code_change, modules}, acc),
    do: %{acc | updated: Enum.reduce(modules, acc.updated, &[module_name(elem(&1, 0)) | &2])}

  defp count({:remove, {module, _pre_purge, _post_purge}}, acc),
    do: %{acc | removed: [module_name(module) | acc.removed]}

  # The instruction DeployEx puts at the head of the script, which applies the configuration
  defp count({:apply, {:erl_eval, :exprs, _args}}, acc), do: %{acc | runtime_config: true}

  defp count({:apply, {module, function, args}}, acc) when is_list(args),
    do: %{acc | applies: ["#{module_name(module)}.#{function}/#{length(args)}" | acc.applies]}

  defp count(instruction, acc) when instruction in [:restart_new_emulator, :restart_emulator],
    do: %{acc | restart_emulator: true}

  defp count(_instruction, acc), do: acc

  defp module_name(module), do: module |> inspect() |> String.trim_leading(":")

  # A relup can hold a script for each version it upgrades from
  defp script_from(up, from_version) do
    case Enum.find(up, fn {vsn, _description, _script} -> to_string(vsn) == from_version end) do
      {_vsn, _description, script} -> {:ok, script}
      nil -> {:error, {:no_script_from, from_version}}
    end
  end

  # As a relup with an empty way back, so it reads like the file it was taken from
  defp format(to_version, from_version, script) do
    relup = {String.to_charlist(to_version), [{String.to_charlist(from_version), [], script}], []}

    ~c"~tp.~n"
    |> :io_lib.format([relup])
    |> IO.chardata_to_string()
  end
end
