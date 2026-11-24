defmodule Deployer.HotUpgrade.VersionUpdate do
  @moduledoc """
  The instruction DeployEx puts at the end of a relup, which moves the version the node
  reports on its traces and on its logs to the one being installed.

  Both are read once, when the application boots, and nothing in a hot upgrade reads them
  again:

    * the OpenTelemetry SDK keeps the resource, with its `service.version`, in the state of
      a few of its processes
    * a `:logger` filter or formatter that stamps the version on every event keeps it in the
      configuration it was added with

  So after a hot upgrade the node runs the new code and still reports the old version. The
  instruction replaces the value where it is held, without restarting anything, so spans
  that are open and events that are queued are kept:

      {apply, {erl_eval, exprs, [Forms, [{'From', <<"0.1.0">>}, {'To', <<"0.2.0">>}]]}}

  As the runtime configuration hook, it carries abstract forms and is evaluated by
  `erl_eval`, so no module is compiled or loaded into the application. The code is in
  `priv/relup/version_update.erl`, next to the one of the runtime configuration hook, and
  becomes forms when DeployEx is compiled.

  ## What it changes

    * **Traces** - only when the OpenTelemetry SDK is running and its `service.version` is
      exactly the version being upgraded from. The resource is replaced in
      `otel_resource_detector`, `otel_tracer_provider_global` and the global batch and simple
      processors, the processes that hold it in the SDK 1.x.
    * **Logs** - every binary equal to the version being upgraded from, in the filters and
      the formatter of each handler, and in the filters and the metadata of the primary
      configuration.

  A version that is derived from something else, or kept anywhere else, is not seen. That is
  what `config_change/3` is for, see the hot upgrades guide.

  ## It never fails the upgrade

  It runs after the point of no return, where an instruction that fails restarts the node, so
  every part of it catches what it raises. For the same reason it is the last instruction of
  the script: every process is running the new code again by then. A relup it cannot be added
  to is installed without it.
  """

  require Logger

  alias Deployer.HotUpgrade.Execute

  # From and To are bound by the instruction, to binaries
  @source_path Path.expand("../../../priv/relup/version_update.erl", __DIR__)
  @external_resource @source_path
  @source File.read!(@source_path)

  {:ok, tokens, _end} = @source |> String.to_charlist() |> :erl_scan.string()
  {:ok, forms} = :erl_parse.parse_exprs(tokens)
  @forms forms

  @doc """
  The Erlang source the instruction evaluates, with `From` and `To` bound to the versions.
  """
  @spec source() :: String.t()
  def source, do: @source

  @doc """
  The relup instruction that moves the version from `from_version` to `to_version`.
  """
  @spec instruction(String.t(), String.t()) :: tuple()
  def instruction(from_version, to_version)
      when is_binary(from_version) and is_binary(to_version) do
    {:apply, {:erl_eval, :exprs, [@forms, [{:From, from_version}, {:To, to_version}]]}}
  end

  @doc """
  Tells the instruction of this module from the one that applies the runtime configuration,
  which is evaluated the same way and binds nothing.
  """
  @spec instruction?(any()) :: boolean()
  def instruction?({:apply, {:erl_eval, :exprs, [_forms, [{:From, _from}, {:To, _to}]]}}),
    do: true

  def instruction?(_instruction), do: false

  @doc """
  Adds the instruction at the end of the script that upgrades from the version the node is
  running, in the relup of the release being installed.

  A script that restarts the VM is left as it is: the node boots on the new version.

  It always returns `:ok`. A relup that cannot be read or written is logged and installed
  without the instruction, which leaves the node as a hot upgrade always left it.
  """
  @spec add_to_relup(Execute.t()) :: :ok
  def add_to_relup(%Execute{current_path: current_path} = data) when is_binary(current_path) do
    from_version = to_string(data.from_version)
    to_version = to_string(data.to_version)
    relup_path = "#{current_path}/releases/#{to_version}/relup"

    with {:ok, [{to_vsn, up, down}]} <- :file.consult(relup_path),
         patched = {to_vsn, Enum.map(up, &append(&1, from_version, to_version)), down},
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

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # A relup has one script for each version it upgrades from
  defp append({from_vsn, descr, script}, from_version, to_version) when is_list(script) do
    if to_string(from_vsn) == from_version and not restarts_vm?(script) do
      {from_vsn, descr, script ++ [instruction(from_version, to_version)]}
    else
      {from_vsn, descr, script}
    end
  end

  defp append(entry, _from_version, _to_version), do: entry

  defp restarts_vm?(script),
    do: Enum.any?(script, &(&1 in [:restart_new_emulator, :restart_emulator]))

  defp not_added(relup_path, reason) do
    Logger.warning(
      "Version update not added to the relup at: #{relup_path}, the node keeps reporting " <>
        "the previous version on traces and logs, reason: #{inspect(reason)}"
    )

    :ok
  end
end
