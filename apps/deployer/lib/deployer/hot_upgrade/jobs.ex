defmodule Deployer.HotUpgrade.Jobs do
  @moduledoc """
  The two instructions DeployEx puts in a relup to give the Oban jobs of the node what a
  shutdown gives them.

  A hot upgrade purges the previous version of every module it loads, and a job that is
  still inside one is killed. Oban records that as a failed attempt and tries the job again,
  so nothing is stuck, but the job loses the attempt and the work it had done. When Oban
  shuts down it does better for the jobs that are almost done: it starts no new job and
  waits for the ones that are running, for its `shutdown_grace_period`.

  The instructions do the same around the code replacement:

      point_of_no_return,
      {apply, {erl_eval, exprs, [Forms, [{'Jobs', pause}]]}},
      ...
      {apply, {erl_eval, exprs, [Forms, [{'Jobs', resume}, {'To', <<"0.2.0">>}]]}}

  The first pauses the queues of this node only, and waits for the running jobs for the
  `shutdown_grace_period` of the instance, 15 seconds unless the application sets another,
  and 20 seconds at most. The last resumes them.

  A job that outlasts the wait keeps running. The upgrade kills it only when a module it is
  inside of is replaced, and Oban then tries it again, so a job in an application that is
  hot-upgraded needs what one that is deployed needs: more than one attempt, and to be safe
  to run again.

  As the other instructions DeployEx adds, they carry abstract forms and are evaluated by
  `erl_eval`. The code is in `priv/relup/jobs_pause.erl` and `jobs_resume.erl`.

  ## What they leave alone

    * An application without Oban, or with a version of it that cannot pause one queue on
      one node.
    * A queue that is already paused, which is not resumed either.
    * The queues of the other nodes.
    * An upgrade that restarts the VM.

  ## They never fail the upgrade

  Both run after the point of no return, where an instruction that fails restarts the node,
  so each catches what it raises. What is to be resumed is written down before any queue is
  paused. A relup they cannot be added to is installed without them.
  """

  require Logger

  alias Deployer.HotUpgrade.Execute
  alias Foundation.Catalog
  alias Foundation.Rpc

  @result_key {:deployex, :jobs}
  @rpc_timeout 10_000

  @typedoc """
  What happened to one Oban instance.

    * `name` - the name of the instance
    * `queues` - the queues that were paused
    * `running` - the jobs that were still running when the wait ended, 0 when all
      finished, and `nil` when it is not known: the queues could not be checked, or the
      wait did not complete
    * `resumed` - `"resumed"` or `"failed"`
  """
  @type result :: %{
          name: String.t(),
          queues: [String.t()],
          running: non_neg_integer() | nil,
          resumed: String.t()
        }

  for {phase, file} <- [pause: "jobs_pause.erl", resume: "jobs_resume.erl"] do
    path = Path.expand("../../../priv/relup/#{file}", __DIR__)
    @external_resource path
    {:ok, tokens, _end} = path |> File.read!() |> String.to_charlist() |> :erl_scan.string()
    {:ok, forms} = :erl_parse.parse_exprs(tokens)
    Module.put_attribute(__MODULE__, :"#{phase}_forms", forms)
  end

  @doc """
  The relup instruction that pauses the queues and waits for the running jobs.
  """
  @spec pause_instruction() :: tuple()
  def pause_instruction,
    do: {:apply, {:erl_eval, :exprs, [@pause_forms, [{:Jobs, :pause}]]}}

  @doc """
  The relup instruction that resumes them, on `to_version`.
  """
  @spec resume_instruction(String.t()) :: tuple()
  def resume_instruction(to_version) when is_binary(to_version),
    do: {:apply, {:erl_eval, :exprs, [@resume_forms, [{:Jobs, :resume}, {:To, to_version}]]}}

  @doc """
  Which of the two an instruction is, `nil` for any other instruction.
  """
  @spec phase(any()) :: :pause | :resume | nil
  def phase({:apply, {:erl_eval, :exprs, [_forms, [{:Jobs, phase} | _]]}})
      when phase in [:pause, :resume],
      do: phase

  def phase(_instruction), do: nil

  @doc """
  Adds both instructions to the script that upgrades from the version the node is running,
  in the relup of the release being installed.

  The pause goes right after the point of no return and the resume at the end, around
  everything else, the pipelines included. A script without a point of no return, or one
  that restarts the VM, is left as it is.

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
  Reads from the node what happened to its jobs, and keeps it with the relup of the upgrade,
  under `jobs`.

  The node is only asked when the relup that was kept has the instructions. It always
  returns `:ok`: a result that cannot be read or kept is logged.
  """
  @spec record(Execute.t()) :: :ok
  def record(%Execute{name: name, node: node} = data) when is_binary(name) do
    from_version = to_string(data.from_version)
    to_version = to_string(data.to_version)

    with %{summary: %{jobs: true}} = relup <- Catalog.relup(name, from_version, to_version),
         {:ok, results} <- read_results(node, to_version),
         :ok <- Catalog.add_relup(name, Map.put(relup, :jobs, results)) do
      Logger.info("Jobs of #{name} #{from_version} -> #{to_version}: #{describe(results)}")
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
  What happened to the jobs, in one sentence.

  ## Examples

      iex> Deployer.HotUpgrade.Jobs.describe([])
      "no Oban queue was running"

      iex> Deployer.HotUpgrade.Jobs.describe([
      ...>   %{name: "Oban", queues: ["default", "mailers"], running: 0, resumed: "resumed"}
      ...> ])
      "Oban paused 2 queues, no job was left running, and resumed"

      iex> Deployer.HotUpgrade.Jobs.describe([
      ...>   %{name: "MyApp.Oban", queues: ["default"], running: 2, resumed: "failed"}
      ...> ])
      "MyApp.Oban paused 1 queue, 2 jobs were still running after the wait, and NOT RESUMED"

      iex> Deployer.HotUpgrade.Jobs.describe([
      ...>   %{name: "Oban", queues: ["default"], running: nil, resumed: "resumed"}
      ...> ])
      "Oban paused 1 queue, its jobs could not be waited for, and resumed"
  """
  @spec describe([result()]) :: String.t()
  def describe([]), do: "no Oban queue was running"

  def describe(results) do
    Enum.map_join(results, ", ", fn result ->
      queues =
        case length(result.queues) do
          1 -> "1 queue"
          count -> "#{count} queues"
        end

      running =
        case result.running do
          nil -> "its jobs could not be waited for"
          0 -> "no job was left running"
          1 -> "1 job was still running after the wait"
          count -> "#{count} jobs were still running after the wait"
        end

      resumed = if result.resumed == "resumed", do: "resumed", else: "NOT RESUMED"

      "#{result.name} paused #{queues}, #{running}, and #{resumed}"
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
         [:point_of_no_return, pause_instruction()] ++ rest ++ [resume_instruction(to_version)]}
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
         for {name, queues, jobs, resumed} <- results do
           %{
             name: inspect(name),
             queues: Enum.map(queues, &to_string/1),
             running: running(jobs),
             resumed: to_string(resumed)
           }
         end}

      other ->
        {:error, {:no_result, other}}
    end
  end

  defp running(:finished), do: 0
  defp running({:running, count}) when is_integer(count), do: count
  # The queues could not be checked, or the pause did not get to the end of the wait
  defp running(_unknown_or_pending), do: nil

  defp not_recorded(name, reason) do
    Logger.warning(
      "What happened to the jobs of #{name} could not be recorded, reason: #{inspect(reason)}"
    )

    :ok
  end

  defp not_added(relup_path, reason) do
    Logger.warning(
      "Job instructions not added to the relup at: #{relup_path}, a job that is running " <>
        "during the upgrade is not waited for, reason: #{inspect(reason)}"
    )

    :ok
  end
end
