defmodule Deployer.HotUpgrade.Pipelines do
  @moduledoc """
  The two instructions DeployEx puts in a relup to keep the Broadway pipelines of the node
  out of the way while its code is replaced.

  A hot upgrade purges the previous version of every module it loads, and a process that is
  still inside one is killed. For a pipeline that is a message half handled. With a producer
  that waits for an acknowledgement, such as RabbitMQ, it is worse than a lost message: the
  processor is restarted and the connection is not, so the message stays delivered and never
  acknowledged, and a consumer with a prefetch of 1 is sent nothing else until it restarts.

  So the pipelines are stopped before any module is loaded and started again once every
  process runs the new code:

      point_of_no_return,
      {apply, {erl_eval, exprs, [Forms, [{'Pipelines', stop}]]}},
      ...
      {apply, {erl_eval, exprs, [Forms, [{'Pipelines', start}, {'To', <<"0.2.0">>}]]}}

  A pipeline is stopped through the supervisor that started it, which is the graceful
  shutdown of Broadway: the messages being handled finish, and what does not finish in time
  goes back to its queue when the connection closes. The pipelines stop at the same time,
  and the upgrade waits up to 45 seconds for them.

  As the other instructions DeployEx adds, they carry abstract forms and are evaluated by
  `erl_eval`. The code is in `priv/relup/pipelines_stop.erl` and `pipelines_start.erl`.

  ## What they leave alone

    * An application without Broadway, or with a version of it that cannot list its
      pipelines.
    * A pipeline that was not started under a name, or by a supervisor that keeps no child
      to start again, such as a `DynamicSupervisor`.
    * An upgrade that restarts the VM, which stops everything anyway.

  ## They never fail the upgrade

  Both run after the point of no return, where an instruction that fails restarts the node,
  so each catches what it raises. What is to be started again is written down before
  anything is stopped. A relup they cannot be added to is installed without them.
  """

  require Logger

  alias Deployer.HotUpgrade.Execute
  alias Foundation.Catalog
  alias Foundation.Rpc

  @result_key {:deployex, :pipelines}
  @rpc_timeout 10_000

  @typedoc """
  What happened to one pipeline.

    * `name` - the name it is registered under
    * `stopped` - `"stopped"`, `"timeout"` when it was still stopping after 45 seconds, or
      `"failed"`
    * `started` - `"started"` or `"failed"`
  """
  @type result :: %{name: String.t(), stopped: String.t(), started: String.t()}

  for {phase, file} <- [stop: "pipelines_stop.erl", start: "pipelines_start.erl"] do
    path = Path.expand("../../../priv/relup/#{file}", __DIR__)
    @external_resource path
    {:ok, tokens, _end} = path |> File.read!() |> String.to_charlist() |> :erl_scan.string()
    {:ok, forms} = :erl_parse.parse_exprs(tokens)
    Module.put_attribute(__MODULE__, :"#{phase}_forms", forms)
  end

  @doc """
  The relup instruction that stops the pipelines.
  """
  @spec stop_instruction() :: tuple()
  def stop_instruction,
    do: {:apply, {:erl_eval, :exprs, [@stop_forms, [{:Pipelines, :stop}]]}}

  @doc """
  The relup instruction that starts them again, on `to_version`.
  """
  @spec start_instruction(String.t()) :: tuple()
  def start_instruction(to_version) when is_binary(to_version),
    do: {:apply, {:erl_eval, :exprs, [@start_forms, [{:Pipelines, :start}, {:To, to_version}]]}}

  @doc """
  Which of the two an instruction is, `nil` for any other instruction.
  """
  @spec phase(any()) :: :stop | :start | nil
  def phase({:apply, {:erl_eval, :exprs, [_forms, [{:Pipelines, phase} | _]]}})
      when phase in [:stop, :start],
      do: phase

  def phase(_instruction), do: nil

  @doc """
  Adds both instructions to the script that upgrades from the version the node is running,
  in the relup of the release being installed.

  The stop goes right after the point of no return: before it, a failed upgrade is given up
  and nothing would start the pipelines again, after it a failure restarts the node. The
  start goes at the end. A script without a point of no return, or one that restarts the
  VM, is left as it is.

  It always returns `:ok`. A relup that cannot be read or written is logged and installed
  without the instructions.
  """
  @spec add_to_relup(Execute.t()) :: :ok
  def add_to_relup(%Execute{current_path: current_path} = data) when is_binary(current_path) do
    from_version = to_string(data.from_version)
    to_version = to_string(data.to_version)
    relup_path = "#{current_path}/releases/#{to_version}/relup"

    with {:ok, [{to_vsn, up, down}]} <- :file.consult(relup_path),
         patched = {to_vsn, Enum.map(up, &add(&1, from_version, to_version)), down},
         :ok <- File.write(relup_path, :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [patched])) do
      :ok
    else
      reason -> not_added(relup_path, reason)
    end
  rescue
    # This runs in the middle of an upgrade, which it must never stop
    error -> not_added(inspect(data.current_path), error)
  end

  def add_to_relup(_data), do: :ok

  @doc """
  Reads from the node what happened to its pipelines, and keeps it with the relup of the
  upgrade, under `pipelines`.

  The node is only asked when the relup that was kept has the instructions. It always
  returns `:ok`: a result that cannot be read or kept is logged.
  """
  @spec record(Execute.t()) :: :ok
  def record(%Execute{name: name, node: node} = data) when is_binary(name) do
    from_version = to_string(data.from_version)
    to_version = to_string(data.to_version)

    with %{summary: %{pipelines: true}} = relup <- Catalog.relup(name, from_version, to_version),
         {:ok, results} <- read_results(node, to_version),
         :ok <- Catalog.add_relup(name, Map.put(relup, :pipelines, results)) do
      Logger.info("Pipelines of #{name} #{from_version} -> #{to_version}: #{describe(results)}")
    else
      # No relup kept, or one without the instructions
      relup when is_map(relup) or is_nil(relup) -> :ok
      reason -> not_recorded(name, reason)
    end
  rescue
    error -> not_recorded(data.name, error)
  end

  def record(_data), do: :ok

  @doc """
  What happened to the pipelines, in one sentence.

  ## Examples

      iex> Deployer.HotUpgrade.Pipelines.describe([])
      "no Broadway pipeline was running"

      iex> Deployer.HotUpgrade.Pipelines.describe([
      ...>   %{name: "MyApp.Orders", stopped: "stopped", started: "started"},
      ...>   %{name: "MyApp.Emails", stopped: "timeout", started: "started"}
      ...> ])
      "MyApp.Orders stopped and started, MyApp.Emails still stopping after 45 seconds and started"
  """
  @spec describe([result()]) :: String.t()
  def describe([]), do: "no Broadway pipeline was running"

  def describe(results) do
    Enum.map_join(results, ", ", fn result ->
      stopped =
        case result.stopped do
          "stopped" -> "stopped"
          "timeout" -> "still stopping after 45 seconds"
          _failed -> "not stopped"
        end

      started = if result.started == "started", do: "started", else: "NOT STARTED"

      "#{result.name} #{stopped} and #{started}"
    end)
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # A relup has one script for each version it upgrades from
  defp add({from_vsn, descr, script}, from_version, to_version) when is_list(script) do
    with true <- to_string(from_vsn) == from_version,
         false <- Enum.any?(script, &(&1 in [:restart_new_emulator, :restart_emulator])),
         {before, [:point_of_no_return | rest]} <-
           Enum.split_while(script, &(&1 != :point_of_no_return)) do
      {from_vsn, descr,
       before ++
         [:point_of_no_return, stop_instruction()] ++ rest ++ [start_instruction(to_version)]}
    else
      _left_alone -> {from_vsn, descr, script}
    end
  end

  defp add(entry, _from_version, _to_version), do: entry

  # The result of another upgrade is not the one of this one
  defp read_results(node, to_version) do
    case Rpc.call(node, :persistent_term, :get, [@result_key, :undefined], @rpc_timeout) do
      {^to_version, results} when is_list(results) ->
        {:ok,
         for {name, stopped, started} <- results do
           %{name: inspect(name), stopped: to_string(stopped), started: to_string(started)}
         end}

      other ->
        {:error, {:no_result, other}}
    end
  end

  defp not_recorded(name, reason) do
    Logger.warning(
      "What happened to the pipelines of #{name} could not be recorded, reason: #{inspect(reason)}"
    )

    :ok
  end

  defp not_added(relup_path, reason) do
    Logger.warning(
      "Pipeline instructions not added to the relup at: #{relup_path}, a message that is " <>
        "being handled during the upgrade can be killed, reason: #{inspect(reason)}"
    )

    :ok
  end
end
