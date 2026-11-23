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

  @typedoc """
  One step of the upgrade, as the node ran it.

    * `instruction` - its name in the relup, such as `suspend` or `load`
    * `key` - which description `explain/1` gives it
    * `subject` - the application an instruction is about, when it names one
    * `targets` - the modules, functions or nodes it acts on
    * `options` - what it was given besides them: the purge options of a `load`, the direction
      of a `code_change`
    * `first` and `last` - its place in the script. Instructions that follow each other and
      differ only in the module they act on are one step
  """
  @type step :: %{
          instruction: String.t(),
          key: atom(),
          subject: String.t() | nil,
          targets: [String.t()],
          options: [String.t()],
          first: pos_integer(),
          last: pos_integer()
        }

  @type t :: %{
          from_version: String.t(),
          to_version: String.t(),
          summary: summary(),
          steps: [step()],
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
             steps: steps(script),
             text: format(to_version, from_version, script),
             inserted_at: NaiveDateTime.utc_now()
           }) do
      :ok
    else
      reason -> not_kept(name, from_version, to_version, reason)
    end
  rescue
    # This runs in the middle of an upgrade, which a record of it must never stop
    error ->
      not_kept(name, to_string(data.from_version), to_string(data.to_version), error)
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

  @doc """
  The steps of an upgrade script in the order the node runs them, for showing what happened.

  Instructions that follow each other and differ only in the module they act on, as the
  `load` of each module of an application does, are one step.

  ## Examples

      iex> Deployer.HotUpgrade.Relup.steps([
      ...>   {:load_object_code, {:myapp, ~c"1.1.0", [MyApp.Worker, MyApp.Web]}},
      ...>   :point_of_no_return,
      ...>   {:suspend, [MyApp.Worker]},
      ...>   {:load, {MyApp.Worker, :brutal_purge, :brutal_purge}},
      ...>   {:load, {MyApp.Web, :brutal_purge, :brutal_purge}},
      ...>   {:code_change, :up, [{MyApp.Worker, []}]},
      ...>   {:resume, [MyApp.Worker]}
      ...> ])
      ...> |> Enum.map(&{&1.instruction, &1.targets, &1.options, &1.first, &1.last})
      [
        {"load_object_code", ["MyApp.Worker", "MyApp.Web"], [], 1, 1},
        {"point_of_no_return", [], [], 2, 2},
        {"suspend", ["MyApp.Worker"], [], 3, 3},
        {"load", ["MyApp.Worker", "MyApp.Web"], ["brutal_purge", "brutal_purge"], 4, 5},
        {"code_change", ["MyApp.Worker"], ["up"], 6, 6},
        {"resume", ["MyApp.Worker"], [], 7, 7}
      ]
  """
  @spec steps(list()) :: [step()]
  def steps(script) when is_list(script) do
    script
    |> Enum.with_index(1)
    |> Enum.map(fn {instruction, index} ->
      instruction |> step() |> Map.merge(%{first: index, last: index})
    end)
    |> Enum.reduce([], &merge_step/2)
    |> Enum.reverse()
  end

  @doc """
  What a step does, in a sentence or two. The purge options of a `load` or a `remove` are
  part of it, since they decide what happens to a process that still runs the old code.

  ## Examples

      iex> Deployer.HotUpgrade.Relup.explain(%{key: :resume, options: []})
      "Lets the paused processes run again, now on the new code."
  """
  @spec explain(map()) :: String.t()
  def explain(%{key: :load_object_code}),
    do:
      "Reads the new object code of these modules from disk into memory, without making it " <>
        "current yet, so they can be switched quickly later."

  def explain(%{key: :point_of_no_return}),
    do:
      "Everything before this only prepared, and a failure there leaves the node as it was. " <>
        "From here on a failure cannot be undone: the node is restarted on the old release."

  def explain(%{key: :suspend}),
    do:
      "Pauses the processes that run these modules, so none is in the middle of a call " <>
        "while its code changes."

  def explain(%{key: :load, options: options}),
    do: "Makes the new version of the module the current one. " <> purge(options)

  def explain(%{key: :remove, options: options}),
    do: "Deletes the module, which the new release no longer has. " <> purge(options)

  def explain(%{key: :code_change}),
    do:
      "Calls code_change/3 in each paused process, so it converts the state it holds to " <>
        "what the new code expects."

  def explain(%{key: :resume}), do: "Lets the paused processes run again, now on the new code."

  def explain(%{key: :purge}),
    do: "Removes the old code of these modules, killing any process that still runs it."

  def explain(%{key: :stop}),
    do: "Stops the processes that run these modules, through their supervisors."

  def explain(%{key: :start}),
    do: "Starts the processes that run these modules again, through their supervisors."

  def explain(%{key: :runtime_config}),
    do:
      "Added by DeployEx. The upgrade has just reset every application to its build time " <>
        "configuration, so this applies the runtime configuration resolved for the new " <>
        "version, with the config_change marker when the release asked for it."

  def explain(%{key: :apply}),
    do:
      "Calls this function. If it fails before the point of no return the upgrade stops " <>
        "with an error, after it the node is restarted."

  def explain(%{key: :sync_nodes}),
    do: "Waits for the other nodes to reach the same point of their upgrade."

  def explain(%{key: :restart_new_emulator}),
    do:
      "Restarts the VM on the new erts, kernel, stdlib and sasl, before the rest of the " <>
        "upgrade runs."

  def explain(%{key: :restart_emulator}),
    do: "Restarts the VM, once every other instruction has run."

  def explain(_step), do: "An instruction DeployEx has no description for."

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # What the two purge options of a load or a remove mean. The first is about code older
  # than the version being replaced, the second about the version being replaced
  defp purge([pre, post]), do: pre_purge(pre) <> " " <> post_purge(post)
  defp purge(_options), do: ""

  defp pre_purge("soft_purge"),
    do:
      "Before it (soft_purge): if a process still runs code from before the version being " <>
        "replaced, the upgrade stops with an error."

  defp pre_purge(_brutal_purge),
    do:
      "Before it (brutal_purge): a process that still runs code from before the version " <>
        "being replaced is killed."

  defp post_purge("soft_purge"),
    do: "After it (soft_purge): the replaced code is purged once no process runs it any more."

  defp post_purge(_brutal_purge),
    do:
      "After it (brutal_purge): the replaced code is purged when the release is made " <>
        "permanent, and a process that still runs it is killed."

  defp step({:load_object_code, {app, vsn, modules}}),
    do: new_step(:load_object_code, names(modules), [], "#{app} #{vsn}")

  defp step({key, {module, pre_purge, post_purge}}) when key in [:load, :remove],
    do: new_step(key, [module_name(module)], [to_string(pre_purge), to_string(post_purge)])

  defp step({key, modules}) when key in [:suspend, :resume, :purge, :stop, :start],
    do: new_step(key, names(modules))

  defp step({:code_change, mode, modules}),
    do: new_step(:code_change, names(modules), [to_string(mode)])

  defp step({:code_change, modules}), do: new_step(:code_change, names(modules))

  defp step({:apply, {:erl_eval, :exprs, _args}}),
    do: %{new_step(:runtime_config, [], [], "runtime configuration") | instruction: "apply"}

  defp step({:apply, {module, function, args}}) when is_list(args),
    do: new_step(:apply, ["#{module_name(module)}.#{function}/#{length(args)}"])

  defp step({:sync_nodes, _id, nodes}) when is_list(nodes),
    do: new_step(:sync_nodes, Enum.map(nodes, &to_string/1))

  defp step(instruction)
       when instruction in [:point_of_no_return, :restart_new_emulator, :restart_emulator],
       do: new_step(instruction, [])

  defp step(instruction) when is_tuple(instruction) and is_atom(elem(instruction, 0)),
    do: %{new_step(:other, []) | instruction: to_string(elem(instruction, 0))}

  defp step(instruction) when is_atom(instruction),
    do: %{new_step(:other, []) | instruction: to_string(instruction)}

  defp step(_instruction), do: %{new_step(:other, []) | instruction: "unknown"}

  defp new_step(key, targets, options \\ [], subject \\ nil),
    do: %{
      instruction: to_string(key),
      key: key,
      subject: subject,
      targets: targets,
      options: options
    }

  # A module can come with a timeout or with what code_change is given, as {module, extra}
  defp names(modules) when is_list(modules) do
    Enum.map(modules, fn
      module when is_tuple(module) -> module |> elem(0) |> module_name()
      module -> module_name(module)
    end)
  end

  defp names(_modules), do: []

  # One load for each module of an application reads as one step
  defp merge_step(%{key: key, options: options} = step, [
         %{key: key, options: options} = previous | steps
       ])
       when key in [:load, :remove] do
    [%{previous | targets: previous.targets ++ step.targets, last: step.last} | steps]
  end

  defp merge_step(step, steps), do: [step | steps]

  defp not_kept(name, from_version, to_version, reason) do
    Logger.warning(
      "Could not keep the relup of #{name} #{from_version} -> #{to_version}, " <>
        "reason: #{inspect(reason)}"
    )

    :ok
  end

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
