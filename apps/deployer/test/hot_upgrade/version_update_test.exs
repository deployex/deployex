defmodule Deployer.HotUpgrade.VersionUpdateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Deployer.HotUpgrade.Execute
  alias Deployer.HotUpgrade.Relup
  alias Deployer.HotUpgrade.VersionUpdate
  alias Foundation.Catalog
  alias Foundation.Fixture.Catalog, as: FixtureCatalog

  doctest Deployer.HotUpgrade.VersionUpdate

  setup :verify_on_exit!

  @up_script [
    {:load_object_code, {:myelixir, ~c"0.2.0", [MyElixir.Web]}},
    :point_of_no_return,
    {:load, {MyElixir.Web, :brutal_purge, :brutal_purge}}
  ]

  # The OpenTelemetry SDK is not a dependency of DeployEx. These stand for the parts of it the
  # instruction calls, with the resource kept in the state of a process as the SDK does
  defmodule Holder do
    use GenServer

    def start(name, state), do: GenServer.start(__MODULE__, state, name: name)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:get, _from, state), do: {:reply, state, state}
  end

  defmodule :otel_resource_detector do
    def get_resource, do: :otel_resource_detector |> GenServer.call(:get) |> elem(1)
  end

  defmodule :otel_resource do
    def create(attributes), do: {:resource, :undefined, {:attributes, 128, attributes}}
    def attributes({:resource, _schema_url, attributes}), do: attributes

    def merge({:resource, _, {:attributes, _, new}}, {:resource, url, {:attributes, limit, old}}),
      do: {:resource, url, {:attributes, limit, Map.merge(old, new)}}
  end

  defmodule :otel_attributes do
    def map({:attributes, _limit, attributes}), do: attributes
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "version-update-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)

    data = %Execute{
      name: "myelixir",
      current_path: tmp,
      from_version: ~c"0.1.0",
      to_version: ~c"0.2.0"
    }

    %{data: data, relup_path: "#{tmp}/releases/0.2.0/relup"}
  end

  defp write_relup!(path, relup) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [relup]))
  end

  defp run(from_version, to_version) do
    {:apply, {:erl_eval, :exprs, [forms, bindings]}} =
      VersionUpdate.instruction(from_version, to_version)

    {:value, result, _bindings} = :erl_eval.exprs(forms, bindings)
    result
  end

  defp resource(version),
    do: :otel_resource.create(%{"service.name": "myelixir", "service.version": version})

  defp start_sdk(version) do
    holders = [
      otel_resource_detector: {:state, resource(version)},
      otel_tracer_provider_global: {:state, [:processors], resource(version), :sampler},
      otel_batch_processor_global: {:idle, {:data, :exporter, resource(version), [:table]}}
    ]

    for {name, state} <- holders do
      {:ok, pid} = Holder.start(name, state)
      on_exit(fn -> Process.exit(pid, :kill) end)
    end

    :ok
  end

  describe "add_to_relup/1" do
    test "ends the script of the version the node runs with the instruction", %{
      data: data,
      relup_path: relup_path
    } do
      down = [{~c"0.1.0", [], [{:load_object_code, {:myelixir, ~c"0.1.0", [MyElixir.Web]}}]}]

      write_relup!(
        relup_path,
        {~c"0.2.0", [{~c"0.0.9", [], @up_script}, {~c"0.1.0", [], @up_script}], down}
      )

      assert :ok = VersionUpdate.add_to_relup(data)

      # release_handler reads the relup the same way
      assert {:ok, [{~c"0.2.0", [{~c"0.0.9", [], other}, {~c"0.1.0", [], script}], ^down}]} =
               :file.consult(relup_path)

      assert other == @up_script
      assert script == @up_script ++ [VersionUpdate.instruction("0.1.0", "0.2.0")]
      assert VersionUpdate.instruction?(List.last(script))
    end

    test "is told apart from the runtime configuration hook in what is kept", %{
      data: data,
      relup_path: relup_path
    } do
      runtime_config_hook = {:apply, {:erl_eval, :exprs, [[{:atom, 0, :ok}], []]}}
      refute VersionUpdate.instruction?(runtime_config_hook)

      write_relup!(relup_path, {~c"0.2.0", [{~c"0.1.0", [], [runtime_config_hook]}], []})
      assert :ok = VersionUpdate.add_to_relup(data)
      assert {:ok, [{_to, [{_from, [], script}], []}]} = :file.consult(relup_path)

      assert %{runtime_config: true, version_update: true, applies: [], instructions: 2} =
               Relup.summary(script)

      assert [%{key: :runtime_config}, %{key: :version_update} = step] = Relup.steps(script)
      assert step.instruction == "apply"
      assert step.subject == "version 0.1.0 to 0.2.0"
      assert Relup.explain(step) =~ "Added by DeployEx"

      assert %{runtime_config: true, version_update: false} =
               Relup.summary([runtime_config_hook])
    end

    test "leaves a script that restarts the VM as it is", %{data: data, relup_path: relup_path} do
      for script <- [
            [:restart_new_emulator | @up_script],
            @up_script ++ [:restart_emulator]
          ] do
        write_relup!(relup_path, {~c"0.2.0", [{~c"0.1.0", [], script}], []})

        assert :ok = VersionUpdate.add_to_relup(data)
        assert {:ok, [{~c"0.2.0", [{~c"0.1.0", [], ^script}], []}]} = :file.consult(relup_path)
      end
    end

    test "never fails the upgrade", %{data: data, relup_path: relup_path} do
      # No relup on disk
      assert capture_log(fn -> assert :ok = VersionUpdate.add_to_relup(data) end) =~
               "Version update not added to the relup"

      # Not a relup
      write_relup!(relup_path, :not_a_relup)

      assert capture_log(fn -> assert :ok = VersionUpdate.add_to_relup(data) end) =~
               "Version update not added to the relup"

      assert :ok = VersionUpdate.add_to_relup(%Execute{})
    end
  end

  describe "record/1" do
    setup %{data: data} do
      FixtureCatalog.cleanup()
      data = %{data | name: "myelixir", node: :myelixir@host}

      keep = fn script ->
        :ok =
          Catalog.add_relup("myelixir", %{
            from_version: "0.1.0",
            to_version: "0.2.0",
            summary: Relup.summary(script),
            steps: Relup.steps(script),
            text: "relup",
            inserted_at: ~N[2026-10-28 12:14:00]
          })
      end

      %{data: data, keep: keep}
    end

    defp expect_result(result) do
      expect(Foundation.RpcMock, :call, fn :myelixir@host,
                                           :persistent_term,
                                           :get,
                                           [{:deployex, :version_update}, :undefined],
                                           _timeout ->
        result
      end)
    end

    test "keeps what the instruction did with the relup", %{data: data, keep: keep} do
      keep.(@up_script ++ [VersionUpdate.instruction("0.1.0", "0.2.0")])

      for {on_node, kept} <- [
            {{:updated, 2}, %{traces: "updated", traces_found: nil, logs: 2}},
            {{{:left_alone, "7.7.7"}, 0},
             %{traces: "left_alone", traces_found: "7.7.7", logs: 0}},
            {{:no_sdk, :failed}, %{traces: "no_sdk", traces_found: nil, logs: "failed"}},
            {{:failed, 1}, %{traces: "failed", traces_found: nil, logs: 1}}
          ] do
        {traces, logs} = on_node
        expect_result({"0.2.0", traces, logs})

        assert capture_log(fn -> assert :ok = VersionUpdate.record(data) end) =~
                 "Version update of myelixir 0.1.0 -> 0.2.0: Traces: "

        assert %{version_update: ^kept, text: "relup"} =
                 Catalog.relup("myelixir", "0.1.0", "0.2.0")

        assert [_traces, _logs] = VersionUpdate.describe(kept, "0.1.0", "0.2.0")
      end
    end

    test "does not ask the node when the relup has no instruction, or none was kept", %{
      data: data,
      keep: keep
    } do
      assert :ok = VersionUpdate.record(data)

      keep.(@up_script)
      assert :ok = VersionUpdate.record(data)
      refute Map.has_key?(Catalog.relup("myelixir", "0.1.0", "0.2.0"), :version_update)
    end

    test "keeps nothing for a result that is not the one of this upgrade", %{
      data: data,
      keep: keep
    } do
      keep.(@up_script ++ [VersionUpdate.instruction("0.1.0", "0.2.0")])

      for answer <- [:undefined, {"0.1.5", :updated, 1}, {:badrpc, :nodedown}] do
        expect_result(answer)

        assert capture_log(fn -> assert :ok = VersionUpdate.record(data) end) =~
                 "could not be recorded"

        refute Map.has_key?(Catalog.relup("myelixir", "0.1.0", "0.2.0"), :version_update)
      end
    end
  end

  describe "the instruction, on logs" do
    setup do
      primary = :logger.get_primary_config()
      on_exit(fn -> :logger.set_primary_config(primary) end)

      handler = :"version_update_#{System.unique_integer([:positive])}"

      filters = [
        version: {&__MODULE__.stamp/2, %{version: "0.1.0", env: "prod"}},
        other: {&__MODULE__.stamp/2, [:keep, "0.1.0-not-the-version", {"0.1.0", 0.1}]}
      ]

      :ok = :logger.add_handler(handler, __MODULE__, %{filters: filters})
      on_exit(fn -> :logger.remove_handler(handler) end)

      %{handler: handler}
    end

    test "replaces the previous version where the logger holds it", %{handler: handler} do
      :ok = :logger.set_primary_config(:metadata, %{version: "0.1.0", node: "0.1.0@host"})

      assert {:no_sdk, 2} = run("0.1.0", "0.2.0")
      assert :persistent_term.get({:deployex, :version_update}) == {"0.2.0", :no_sdk, 2}

      assert {:ok, %{filters: filters}} = :logger.get_handler_config(handler)

      assert filters == [
               version: {&__MODULE__.stamp/2, %{version: "0.2.0", env: "prod"}},
               other: {&__MODULE__.stamp/2, [:keep, "0.1.0-not-the-version", {"0.2.0", 0.1}]}
             ]

      assert %{metadata: %{version: "0.2.0", node: "0.1.0@host"}} = :logger.get_primary_config()
    end

    test "changes nothing when no value is the previous version", %{handler: handler} do
      {:ok, before} = :logger.get_handler_config(handler)

      assert {:no_sdk, 0} = run("0.0.9", "0.2.0")
      assert {:ok, ^before} = :logger.get_handler_config(handler)
    end
  end

  describe "the instruction, on traces" do
    test "replaces the resource in every process that holds it" do
      start_sdk("0.1.0")

      assert {:updated, 0} = run("0.1.0", "0.2.0")

      new = resource("0.2.0")
      assert :otel_resource_detector.get_resource() == new

      # What is around the resource is kept
      assert {:state, [:processors], ^new, :sampler} =
               GenServer.call(:otel_tracer_provider_global, :get)

      assert {:idle, {:data, :exporter, ^new, [:table]}} =
               GenServer.call(:otel_batch_processor_global, :get)
    end

    test "leaves a version it did not expect alone" do
      start_sdk("7.7.7")

      assert {{:left_alone, "7.7.7"}, 0} = run("0.1.0", "0.2.0")
      assert :otel_resource_detector.get_resource() == resource("7.7.7")
    end

    test "leaves the detector alone when a process that exports could not be replaced" do
      start_sdk("0.1.0")

      # A batch processor that takes longer than the instruction waits for it
      Process.exit(Process.whereis(:otel_batch_processor_global), :kill)
      test_pid = self()

      busy =
        spawn(fn ->
          Process.register(self(), :otel_batch_processor_global)
          send(test_pid, :registered)
          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(busy, :kill) end)
      assert_receive :registered

      assert {:failed, 0} = run("0.1.0", "0.2.0")

      # The detector still says the version the node exports, so the result of the next
      # upgrade does not claim a version that was never reached
      assert :otel_resource_detector.get_resource() == resource("0.1.0")
      assert {{:left_alone, "0.1.0"}, 0} = run("0.2.0", "0.3.0")
    end

    test "says so when the resource has no service.version" do
      holders = [otel_resource_detector: {:state, :otel_resource.create(%{"service.name": "x"})}]

      for {name, state} <- holders do
        {:ok, pid} = Holder.start(name, state)
        on_exit(fn -> Process.exit(pid, :kill) end)
      end

      assert {{:left_alone, :undefined}, 0} = run("0.1.0", "0.2.0")
    end

    test "does nothing without the SDK, and does not raise when it misbehaves" do
      assert {:no_sdk, 0} = run("0.1.0", "0.2.0")

      # A detector that does not answer as the SDK does
      {:ok, pid} = Holder.start(:otel_resource_detector, :not_a_state)
      on_exit(fn -> Process.exit(pid, :kill) end)

      assert {:failed, 0} = run("0.1.0", "0.2.0")
    end
  end

  # The logger handler and the filter of these tests
  def log(_event, _config), do: :ok
  def stamp(event, _config), do: event
end
