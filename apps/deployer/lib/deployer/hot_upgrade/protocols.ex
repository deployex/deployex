defmodule Deployer.HotUpgrade.Protocols do
  @moduledoc """
  The instruction DeployEx puts in a relup, after the last module it loads, which loads
  the consolidated protocols of the release being installed.

  An Elixir release consolidates its protocols: each one is compiled again with the list of
  its implementations, and kept in `releases/<version>/consolidated`, outside of every
  application. An appup describes one application, so no appup covers them, and
  `release_handler` loads the new implementations and leaves the protocols as they were when
  the node booted.

  A release that adds an implementation, a struct that derives `Jason.Encoder` or
  implements `String.Chars` or `Phoenix.Param`, then installs without an error, and the
  first value of that struct that reaches the protocol raises `Protocol.UndefinedError`.
  Nothing fails before that, and a restart makes it go away, which is why a full deployment
  never shows it.

  The instruction loads every consolidated protocol of the new release whose code is not the
  one that is loaded, and moves the code path to its directory:

      {apply, {erl_eval, exprs, [Forms, [{'Protocols', reload}, {'Root', Root}, {'To', <<"0.2.0">>}]]}}

  It goes right after the last module the script loads, so what the script runs next, a
  `code_change`, a resumed process or a function the appup calls, already finds the
  protocols of the release, and before DeployEx starts the pipelines and resumes the queues
  again. As the other instructions DeployEx adds, it carries abstract forms and is evaluated
  by `erl_eval`. The code is in `priv/relup/protocols.erl`.

  ## What it leaves alone

    * A protocol whose consolidated code did not change, which is most of them.
    * A release without consolidated protocols: an Erlang or a Gleam one, or an Elixir one
      built with `consolidate_protocols: false`.
    * An upgrade that restarts the VM, which loads everything again.

  ## It never fails the upgrade

  It runs after the point of no return, where an instruction that fails restarts the node,
  so it catches what it raises, protocol by protocol. A relup it cannot be added to is
  installed without it.
  """

  require Logger

  alias Deployer.HotUpgrade.Execute
  alias Foundation.Catalog
  alias Foundation.Rpc

  @result_key {:deployex, :protocols}
  @rpc_timeout 10_000

  @typedoc """
  What the instruction did on the node.

    * `reloaded` - the protocols whose consolidated code was loaded
    * `failed` - the ones that could not be loaded
    * `consolidated` - false when the release has no consolidated protocols
  """
  @type result :: %{reloaded: [String.t()], failed: [String.t()], consolidated: boolean()}

  path = Path.expand("../../../priv/relup/protocols.erl", __DIR__)
  @external_resource path
  {:ok, tokens, _end} = path |> File.read!() |> String.to_charlist() |> :erl_scan.string()
  {:ok, forms} = :erl_parse.parse_exprs(tokens)
  @forms forms

  @doc """
  The relup instruction that loads the consolidated protocols of `to_version`, from the
  release directory `root`, the one the node runs from.
  """
  @spec instruction(String.t(), String.t()) :: tuple()
  def instruction(root, to_version) when is_binary(root) and is_binary(to_version) do
    bindings = [{:Protocols, :reload}, {:Root, root}, {:To, to_version}]
    {:apply, {:erl_eval, :exprs, [@forms, bindings]}}
  end

  @doc """
  Tells the instruction of this module from the others DeployEx adds.
  """
  @spec instruction?(any()) :: boolean()
  def instruction?({:apply, {:erl_eval, :exprs, [_forms, [{:Protocols, :reload} | _]]}}),
    do: true

  def instruction?(_instruction), do: false

  @doc """
  Adds the instruction after the last module loaded by the script that upgrades from the
  version the node is running, in the relup of the release being installed. A script that
  loads no module has it at its end.

  A script that restarts the VM is left as it is.

  It always returns `:ok`. A relup that cannot be read or written is logged and installed
  without the instruction.
  """
  @spec add_to_relup(Execute.t()) :: :ok
  def add_to_relup(%Execute{current_path: current_path} = data) when is_binary(current_path) do
    from_version = to_string(data.from_version)
    to_version = to_string(data.to_version)
    relup_path = "#{current_path}/releases/#{to_version}/relup"

    with {:ok, [{to_vsn, up, down}]} <- :file.consult(relup_path),
         instruction = instruction(current_path, to_version),
         patched = {to_vsn, Enum.map(up, &append(&1, from_version, instruction)), down},
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
  Reads from the node which protocols were loaded, and keeps it with the relup of the
  upgrade, under `protocols`.

  The node is only asked when the relup that was kept has the instruction. It always returns
  `:ok`: a result that cannot be read or kept is logged.
  """
  @spec record(Execute.t()) :: :ok
  def record(%Execute{name: name, node: node} = data) when is_binary(name) do
    from_version = to_string(data.from_version)
    to_version = to_string(data.to_version)

    with %{summary: %{protocols: true}} = relup <- Catalog.relup(name, from_version, to_version),
         {:ok, result} <- read_result(node, to_version),
         :ok <- Catalog.add_relup(name, Map.put(relup, :protocols, result)) do
      Logger.info("Protocols of #{name} #{from_version} -> #{to_version}: #{describe(result)}")
    else
      # No relup kept, or one without the instruction
      relup when is_map(relup) or is_nil(relup) -> :ok
      reason -> not_recorded(name, reason)
    end
  rescue
    error -> not_recorded(data.name, error)
  end

  def record(_data), do: :ok

  @doc """
  What the instruction did, in one sentence.

  ## Examples

      iex> result = %{reloaded: ["Jason.Encoder", "String.Chars"], failed: [], consolidated: true}
      iex> Deployer.HotUpgrade.Protocols.describe(result)
      "2 consolidated protocols loaded: Jason.Encoder, String.Chars"

      iex> result = %{reloaded: [], failed: [], consolidated: true}
      iex> Deployer.HotUpgrade.Protocols.describe(result)
      "no consolidated protocol changed"

      iex> result = %{reloaded: ["Jason.Encoder"], failed: ["Phoenix.Param"], consolidated: true}
      iex> Deployer.HotUpgrade.Protocols.describe(result)
      "1 consolidated protocol loaded: Jason.Encoder, and NOT LOADED: Phoenix.Param"

      iex> result = %{reloaded: [], failed: [], consolidated: false}
      iex> Deployer.HotUpgrade.Protocols.describe(result)
      "the release has no consolidated protocols"
  """
  @spec describe(result()) :: String.t()
  def describe(%{consolidated: false}), do: "the release has no consolidated protocols"

  def describe(%{reloaded: reloaded, failed: failed}) do
    loaded =
      case reloaded do
        [] -> "no consolidated protocol changed"
        [one] -> "1 consolidated protocol loaded: #{one}"
        many -> "#{length(many)} consolidated protocols loaded: #{Enum.join(many, ", ")}"
      end

    if failed == [], do: loaded, else: "#{loaded}, and NOT LOADED: #{Enum.join(failed, ", ")}"
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # A relup has one script for each version it upgrades from
  defp append({from_vsn, descr, script}, from_version, instruction) when is_list(script) do
    restarts_vm? = Enum.any?(script, &(&1 in [:restart_new_emulator, :restart_emulator]))

    if to_string(from_vsn) == from_version and not restarts_vm? do
      {from_vsn, descr, place(script, instruction)}
    else
      {from_vsn, descr, script}
    end
  end

  defp append(entry, _from_version, _instruction), do: entry

  # Right after the last module the script loads: every implementation is loaded by then,
  # and what the script runs next, a code_change, a resumed process or a function the appup
  # calls, already finds the protocols of the release. A script that loads nothing has it
  # at its end
  defp place(script, instruction) do
    case script |> Enum.reverse() |> Enum.split_while(&(not match?({:load, _module}, &1))) do
      {_script, []} -> script ++ [instruction]
      {rest, until_load} -> Enum.reverse(until_load) ++ [instruction | Enum.reverse(rest)]
    end
  end

  # The result of another upgrade is not the one of this one
  defp read_result(node, to_version) do
    case Rpc.call(node, :persistent_term, :get, [@result_key, :undefined], @rpc_timeout) do
      {^to_version, :none} ->
        {:ok, %{reloaded: [], failed: [], consolidated: false}}

      {^to_version, protocols} when is_list(protocols) ->
        {:ok,
         %{
           reloaded: for({module, :reloaded} <- protocols, do: inspect(module)),
           failed: for({module, :failed} <- protocols, do: inspect(module)),
           consolidated: true
         }}

      other ->
        {:error, {:no_result, other}}
    end
  end

  defp not_recorded(name, reason) do
    Logger.warning(
      "Which protocols of #{name} were loaded could not be recorded, reason: #{inspect(reason)}"
    )

    :ok
  end

  defp not_added(relup_path, reason) do
    Logger.warning(
      "Protocol instruction not added to the relup at: #{relup_path}, a protocol " <>
        "implementation the release adds is not known to the node until it restarts, " <>
        "reason: #{inspect(reason)}"
    )

    :ok
  end
end
