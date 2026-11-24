defmodule Deployer.HotUpgrade.PipelinesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Deployer.HotUpgrade.Execute
  alias Deployer.HotUpgrade.Pipelines
  alias Deployer.HotUpgrade.Relup
  alias Foundation.Catalog
  alias Foundation.Fixture.Catalog, as: FixtureCatalog

  doctest Deployer.HotUpgrade.Pipelines

  setup :verify_on_exit!

  @result_key {:deployex, :pipelines}
  @running_key {__MODULE__, :running}

  @load {:load, {MyElixir.Web, :brutal_purge, :brutal_purge}}
  @up_script [
    {:load_object_code, {:myelixir, ~c"0.2.0", [MyElixir.Web]}},
    :point_of_no_return,
    @load
  ]

  # Broadway is not a dependency of DeployEx. This stands for the one function of it the
  # instruction calls, and answers with the names the test put aside
  defmodule Elixir.Broadway do
    def all_running, do: :persistent_term.get({Deployer.HotUpgrade.PipelinesTest, :running}, [])
  end

  # A pipeline, as far as the instruction can tell: a named process under a supervisor
  defmodule Pipeline do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, name, name: name)

    @impl true
    def init(name) do
      Process.flag(:trap_exit, true)
      {:ok, name}
    end

    # What a graceful shutdown lets finish. The test is gone when it is the one stopping
    @impl true
    def terminate(_reason, name) do
      if test = Process.whereis(:pipelines_test), do: send(test, {:drained, name})
    end
  end

  # A process that is not a supervisor and starts a pipeline of its own
  defmodule Owner do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, name)

    @impl true
    def init(name) do
      {:ok, _pid} = Pipeline.start_link(name)
      {:ok, name}
    end
  end

  setup do
    Process.register(self(), :pipelines_test)

    on_exit(fn ->
      :persistent_term.erase(@result_key)
      :persistent_term.erase(@running_key)
    end)

    tmp = Path.join(System.tmp_dir!(), "pipelines-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)

    data = %Execute{
      name: "myelixir",
      node: :myelixir@host,
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

  defp run({:apply, {:erl_eval, :exprs, [forms, bindings]}}) do
    {:value, :ok, _bindings} = :erl_eval.exprs(forms, bindings)
    :persistent_term.get(@result_key, :nothing)
  end

  defp start_supervised_pipelines!(names) do
    children = for name <- names, do: Supervisor.child_spec({Pipeline, name}, id: name)

    supervisor =
      start_supervised!(%{
        id: :app,
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
      })

    :persistent_term.put(@running_key, names)
    supervisor
  end

  describe "add_to_relup/1" do
    test "stops right after the point of no return and starts at the end", %{
      data: data,
      relup_path: relup_path
    } do
      write_relup!(
        relup_path,
        {~c"0.2.0", [{~c"0.0.9", [], @up_script}, {~c"0.1.0", [], @up_script}], []}
      )

      assert :ok = Pipelines.add_to_relup(data)

      assert {:ok, [{~c"0.2.0", [{~c"0.0.9", [], other}, {~c"0.1.0", [], script}], []}]} =
               :file.consult(relup_path)

      assert other == @up_script

      assert [
               {:load_object_code, _},
               :point_of_no_return,
               stop,
               @load,
               start
             ] = script

      assert stop == Pipelines.stop_instruction()
      assert start == Pipelines.start_instruction("0.2.0")
      assert Pipelines.phase(stop) == :stop
      assert Pipelines.phase(start) == :start
      assert Pipelines.phase(@load) == nil

      assert %{pipelines: true, runtime_config: false, version_update: false, applies: []} =
               Relup.summary(script)

      assert [_load_object_code, _point, stop_step, _load, start_step] = Relup.steps(script)
      assert %{key: :pipelines_stop, instruction: "apply"} = stop_step
      assert %{key: :pipelines_start, instruction: "apply"} = start_step
      assert Relup.explain(stop_step) =~ "Stops the Broadway pipelines"
      assert Relup.explain(start_step) =~ "Starts the pipelines"
    end

    test "leaves alone a script without a point of no return, or one that restarts the VM", %{
      data: data,
      relup_path: relup_path
    } do
      for script <- [
            [@load],
            [:restart_new_emulator | @up_script],
            @up_script ++ [:restart_emulator]
          ] do
        write_relup!(relup_path, {~c"0.2.0", [{~c"0.1.0", [], script}], []})

        assert :ok = Pipelines.add_to_relup(data)
        assert {:ok, [{~c"0.2.0", [{~c"0.1.0", [], ^script}], []}]} = :file.consult(relup_path)
      end
    end

    test "never fails the upgrade", %{data: data, relup_path: relup_path} do
      assert capture_log(fn -> assert :ok = Pipelines.add_to_relup(data) end) =~
               "Pipeline instructions not added to the relup"

      write_relup!(relup_path, :not_a_relup)

      assert capture_log(fn -> assert :ok = Pipelines.add_to_relup(data) end) =~
               "Pipeline instructions not added to the relup"

      assert :ok = Pipelines.add_to_relup(%Execute{})
    end
  end

  describe "the instructions" do
    test "stop each pipeline through its supervisor and start it again" do
      supervisor = start_supervised_pipelines!([:orders_pipeline, :emails_pipeline])
      before = Process.whereis(:orders_pipeline)

      assert [
               {:orders_pipeline, ^supervisor, :orders_pipeline, :stopped},
               {:emails_pipeline, ^supervisor, :emails_pipeline, :stopped}
             ] = run(Pipelines.stop_instruction())

      # Stopped by their supervisor, which is the graceful shutdown, and not started again
      assert_received {:drained, :orders_pipeline}
      assert_received {:drained, :emails_pipeline}
      assert Process.whereis(:orders_pipeline) == nil
      assert Process.whereis(:emails_pipeline) == nil

      assert {"0.2.0",
              [
                {:orders_pipeline, :stopped, :started},
                {:emails_pipeline, :stopped, :started}
              ]} = run(Pipelines.start_instruction("0.2.0"))

      assert is_pid(Process.whereis(:orders_pipeline))
      assert Process.whereis(:orders_pipeline) != before
      assert is_pid(Process.whereis(:emails_pipeline))
    end

    test "leave alone a pipeline they could not start again" do
      {:ok, dynamic} = start_supervised({DynamicSupervisor, strategy: :one_for_one})
      {:ok, pid} = DynamicSupervisor.start_child(dynamic, {Pipeline, :dynamic_pipeline})

      # One without a process, and one that a supervisor keeps no child for
      :persistent_term.put(@running_key, [:gone_pipeline, :dynamic_pipeline, {:via, Registry, :x}])

      assert [] = run(Pipelines.stop_instruction())
      assert Process.whereis(:dynamic_pipeline) == pid
      assert {"0.2.0", []} = run(Pipelines.start_instruction("0.2.0"))
    end

    test "leave alone a pipeline that is a temporary child" do
      supervisor =
        start_supervised!(%{
          id: :app,
          start:
            {Supervisor, :start_link,
             [
               [
                 Supervisor.child_spec({Pipeline, :kept_pipeline}, id: :kept_pipeline),
                 Supervisor.child_spec({Pipeline, :temporary_pipeline},
                   id: :temporary_pipeline,
                   restart: :temporary
                 )
               ],
               [strategy: :one_for_one]
             ]}
        })

      :persistent_term.put(@running_key, [:kept_pipeline, :temporary_pipeline])
      temporary = Process.whereis(:temporary_pipeline)

      assert [{:kept_pipeline, ^supervisor, :kept_pipeline, :stopped}] =
               run(Pipelines.stop_instruction())

      # Its supervisor would have forgotten it, and nothing could start it again
      assert Process.whereis(:temporary_pipeline) == temporary
    end

    test "do not ask a process that is not a supervisor for its children" do
      owner = start_supervised!({Owner, :owned_pipeline})
      :persistent_term.put(@running_key, [:owned_pipeline])
      pipeline = Process.whereis(:owned_pipeline)

      assert [] = run(Pipelines.stop_instruction())

      # A call it does not know would have stopped it, and the pipeline with it
      assert Process.alive?(owner)
      assert Process.whereis(:owned_pipeline) == pipeline
    end

    test "do not wait for a supervisor that does not answer" do
      supervisor = start_supervised_pipelines!([:orders_pipeline])
      :sys.suspend(supervisor)

      started_at = System.monotonic_time(:millisecond)

      # Nothing is found within the 5 seconds given to look for the pipelines
      assert [] = run(Pipelines.stop_instruction())

      waited = System.monotonic_time(:millisecond) - started_at
      assert waited >= 5_000 and waited < 8_000

      # And a start is given up after 10 seconds, to happen when the supervisor answers
      :ok = :sys.resume(supervisor)
      :ok = Supervisor.terminate_child(supervisor, :orders_pipeline)
      :sys.suspend(supervisor)

      :persistent_term.put(@result_key, [
        {:orders_pipeline, supervisor, :orders_pipeline, :timeout}
      ])

      assert {"0.2.0", [{:orders_pipeline, :timeout, :timeout}]} =
               run(Pipelines.start_instruction("0.2.0"))

      :ok = :sys.resume(supervisor)
      # Any call is answered after the start that was waiting
      _children = Supervisor.which_children(supervisor)
      assert is_pid(Process.whereis(:orders_pipeline))
    end

    test "take a pipeline that is running again for started" do
      supervisor = start_supervised_pipelines!([:orders_pipeline])

      # Its supervisor was started again during the upgrade, under another pid
      gone = spawn(fn -> :ok end)

      :persistent_term.put(@result_key, [
        {:orders_pipeline, gone, :orders_pipeline, :stopped},
        {:other_pipeline, supervisor, :no_such_child, :stopped}
      ])

      assert {"0.2.0",
              [{:orders_pipeline, :stopped, :started}, {:other_pipeline, :stopped, :failed}]} =
               run(Pipelines.start_instruction("0.2.0"))
    end

    test "do nothing when no pipeline is running" do
      assert [] = run(Pipelines.stop_instruction())
      assert {"0.2.0", []} = run(Pipelines.start_instruction("0.2.0"))
    end

    test "start what was written down, and survive what they cannot read" do
      supervisor = start_supervised_pipelines!([:orders_pipeline])
      :ok = Supervisor.terminate_child(supervisor, :orders_pipeline)

      # As the stop leaves it before it stops anything, and a child that is not there
      :persistent_term.put(@result_key, [
        {:orders_pipeline, supervisor, :orders_pipeline, :pending},
        {:other_pipeline, supervisor, :no_such_child, :timeout}
      ])

      assert {"0.2.0",
              [{:orders_pipeline, :pending, :started}, {:other_pipeline, :timeout, :failed}]} =
               run(Pipelines.start_instruction("0.2.0"))

      assert is_pid(Process.whereis(:orders_pipeline))

      # The result of an earlier upgrade is not a list of pipelines to start
      assert {"0.3.0", []} = run(Pipelines.start_instruction("0.3.0"))
    end
  end

  describe "record/1" do
    setup %{data: data} do
      FixtureCatalog.cleanup()

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

      with_instructions =
        [:point_of_no_return, Pipelines.stop_instruction(), @load] ++
          [Pipelines.start_instruction("0.2.0")]

      %{data: data, keep: keep, with_instructions: with_instructions}
    end

    defp expect_result(result) do
      expect(Foundation.RpcMock, :call, fn :myelixir@host,
                                           :persistent_term,
                                           :get,
                                           [{:deployex, :pipelines}, :undefined],
                                           _timeout ->
        result
      end)
    end

    test "keeps what happened to each pipeline with the relup", ctx do
      ctx.keep.(ctx.with_instructions)

      expect_result(
        {"0.2.0", [{MyElixir.Orders, :stopped, :started}, {MyElixir.Emails, :timeout, :failed}]}
      )

      log = capture_log(fn -> assert :ok = Pipelines.record(ctx.data) end)
      assert log =~ "Pipelines of myelixir 0.1.0 -> 0.2.0: MyElixir.Orders stopped and started"
      assert log =~ "MyElixir.Emails still stopping after 30 seconds and NOT STARTED"

      assert %{
               text: "relup",
               pipelines: [
                 %{name: "MyElixir.Orders", stopped: "stopped", started: "started"},
                 %{name: "MyElixir.Emails", stopped: "timeout", started: "failed"}
               ]
             } = Catalog.relup("myelixir", "0.1.0", "0.2.0")
    end

    test "keeps an empty list for an application without pipelines", ctx do
      ctx.keep.(ctx.with_instructions)
      expect_result({"0.2.0", []})

      assert capture_log(fn -> assert :ok = Pipelines.record(ctx.data) end) =~
               "no Broadway pipeline was running"

      assert %{pipelines: []} = Catalog.relup("myelixir", "0.1.0", "0.2.0")
    end

    test "does not ask the node when the relup has no instructions, or none was kept", ctx do
      assert :ok = Pipelines.record(ctx.data)

      ctx.keep.([@load])
      assert :ok = Pipelines.record(ctx.data)
      refute Map.has_key?(Catalog.relup("myelixir", "0.1.0", "0.2.0"), :pipelines)
    end

    test "keeps nothing for a result that is not the one of this upgrade", ctx do
      ctx.keep.(ctx.with_instructions)

      for answer <- [:undefined, [], {"0.1.5", []}, {:badrpc, :nodedown}] do
        expect_result(answer)

        assert capture_log(fn -> assert :ok = Pipelines.record(ctx.data) end) =~
                 "could not be recorded"

        refute Map.has_key?(Catalog.relup("myelixir", "0.1.0", "0.2.0"), :pipelines)
      end
    end
  end
end
