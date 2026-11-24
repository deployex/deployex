defmodule Deployer.HotUpgrade.JobsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Deployer.HotUpgrade.Execute
  alias Deployer.HotUpgrade.Jobs
  alias Deployer.HotUpgrade.Pipelines
  alias Deployer.HotUpgrade.Relup
  alias Foundation.Catalog
  alias Foundation.Fixture.Catalog, as: FixtureCatalog

  doctest Deployer.HotUpgrade.Jobs

  setup :verify_on_exit!

  @result_key {:deployex, :jobs}

  @load {:load, {MyElixir.Web, :brutal_purge, :brutal_purge}}
  @up_script [
    {:load_object_code, {:myelixir, ~c"0.2.0", [MyElixir.Web]}},
    :point_of_no_return,
    @load
  ]

  # Oban is not a dependency of DeployEx. This stands for the functions of it the
  # instructions call, with the queues kept in an Agent
  defmodule Elixir.Oban do
    @queues Deployer.HotUpgrade.JobsTest.Queues

    def check_all_queues(_name) do
      for {queue, state} <- Agent.get(@queues, & &1), do: Map.put(state, :queue, queue)
    end

    def pause_queue(_name, queue: queue, local_only: true), do: put(queue, :paused, true)
    def resume_queue(_name, queue: queue, local_only: true), do: put(queue, :paused, false)

    # A queue that is not there raises here, in the caller, as Oban does
    def put(queue, key, value) do
      true = Agent.get(@queues, &Map.has_key?(&1, queue))
      Agent.update(@queues, &put_in(&1, [queue, key], value))
    end
  end

  setup do
    on_exit(fn -> :persistent_term.erase(@result_key) end)

    tmp = Path.join(System.tmp_dir!(), "jobs-#{System.unique_integer([:positive])}")
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

  # An Oban instance as the instruction finds it: its configuration in the registry of Oban
  defp start_oban!(grace_ms, queues) do
    start_supervised!({Registry, keys: :unique, name: Oban.Registry})

    start_supervised!(%{
      id: :queues,
      start: {Agent, :start_link, [fn -> queues end, [name: __MODULE__.Queues]]}
    })

    config = %{__struct__: Oban.Config, shutdown_grace_period: grace_ms}
    {:ok, _owner} = Registry.register(Oban.Registry, Oban, config)
    # Oban registers its other processes there too, under other keys
    {:ok, _owner} = Registry.register(Oban.Registry, {Oban, Oban.Notifier}, nil)
    :ok
  end

  defp queue(name), do: Agent.get(__MODULE__.Queues, &Map.fetch!(&1, name))

  describe "add_to_relup/1" do
    test "pauses right after the point of no return and resumes at the end, around the pipelines",
         %{data: data, relup_path: relup_path} do
      write_relup!(
        relup_path,
        {~c"0.2.0", [{~c"0.0.9", [], @up_script}, {~c"0.1.0", [], @up_script}], []}
      )

      assert :ok = Pipelines.add_to_relup(data)
      assert :ok = Jobs.add_to_relup(data)

      assert {:ok, [{~c"0.2.0", [{~c"0.0.9", [], other}, {~c"0.1.0", [], script}], []}]} =
               :file.consult(relup_path)

      assert other == @up_script

      assert [{:load_object_code, _}, :point_of_no_return, pause, stop, @load, start, resume] =
               script

      assert pause == Jobs.pause_instruction()
      assert resume == Jobs.resume_instruction("0.2.0")
      assert Jobs.phase(pause) == :pause
      assert Jobs.phase(resume) == :resume
      assert Jobs.phase(stop) == nil
      assert Pipelines.phase(stop) == :stop
      assert Pipelines.phase(start) == :start
      assert Pipelines.phase(pause) == nil

      assert %{jobs: true, pipelines: true, runtime_config: false, applies: []} =
               Relup.summary(script)

      assert [_load_object_code, _point, pause_step, _stop, _load, _start, resume_step] =
               Relup.steps(script)

      assert %{key: :jobs_pause, instruction: "apply"} = pause_step
      assert %{key: :jobs_resume, instruction: "apply"} = resume_step
      assert Relup.explain(pause_step) =~ "Pauses the Oban queues"
      assert Relup.explain(resume_step) =~ "Resumes the queues"
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

        assert :ok = Jobs.add_to_relup(data)
        assert {:ok, [{~c"0.2.0", [{~c"0.1.0", [], ^script}], []}]} = :file.consult(relup_path)
      end
    end

    test "never fails the upgrade", %{data: data, relup_path: relup_path} do
      assert capture_log(fn -> assert :ok = Jobs.add_to_relup(data) end) =~
               "Job instructions not added to the relup"

      write_relup!(relup_path, :not_a_relup)

      assert capture_log(fn -> assert :ok = Jobs.add_to_relup(data) end) =~
               "Job instructions not added to the relup"

      assert :ok = Jobs.add_to_relup(%Execute{})
    end
  end

  describe "the instructions" do
    test "pause the queues, wait for the running jobs and resume" do
      start_oban!(5_000, %{
        "default" => %{paused: false, running: [11, 12]},
        "mailers" => %{paused: false, running: []},
        "maintenance" => %{paused: true, running: []}
      })

      # The jobs finish while the instruction waits for them
      finisher =
        Task.async(fn ->
          Process.sleep(300)
          # Paused by then, and still waited for
          paused? = queue("default").paused and queue("mailers").paused
          Oban.put("default", :running, [])
          paused?
        end)

      started_at = System.monotonic_time(:millisecond)

      assert [{Oban, ["default", "mailers"], :finished}] = run(Jobs.pause_instruction())

      assert System.monotonic_time(:millisecond) - started_at >= 300
      assert Task.await(finisher)

      assert {"0.2.0", [{Oban, ["default", "mailers"], :finished, :resumed}]} =
               run(Jobs.resume_instruction("0.2.0"))

      refute queue("default").paused
      refute queue("mailers").paused
      # The one that was paused before the upgrade stays paused
      assert queue("maintenance").paused
    end

    test "stop waiting after the grace period of the instance" do
      start_oban!(300, %{"default" => %{paused: false, running: [11, 12]}})

      started_at = System.monotonic_time(:millisecond)

      assert [{Oban, ["default"], {:running, 2}}] = run(Jobs.pause_instruction())

      waited = System.monotonic_time(:millisecond) - started_at
      assert waited >= 300 and waited < 3_000

      assert {"0.2.0", [{Oban, ["default"], {:running, 2}, :resumed}]} =
               run(Jobs.resume_instruction("0.2.0"))

      refute queue("default").paused
    end

    test "do nothing when Oban is not running" do
      assert [] = run(Jobs.pause_instruction())
      assert {"0.2.0", []} = run(Jobs.resume_instruction("0.2.0"))
    end

    test "resume what was written down, and survive what they cannot read" do
      start_oban!(5_000, %{"default" => %{paused: true, running: []}})

      # As the pause leaves it before the wait, and a queue that is not there
      :persistent_term.put(@result_key, [
        {Oban, ["default"], :pending},
        {Other.Oban, ["missing"], :pending}
      ])

      assert {"0.2.0",
              [
                {Oban, ["default"], :pending, :resumed},
                {Other.Oban, ["missing"], :pending, :failed}
              ]} = run(Jobs.resume_instruction("0.2.0"))

      refute queue("default").paused

      # The result of an earlier upgrade is not a list of queues to resume
      assert {"0.3.0", []} = run(Jobs.resume_instruction("0.3.0"))
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
        [:point_of_no_return, Jobs.pause_instruction(), @load, Jobs.resume_instruction("0.2.0")]

      %{data: data, keep: keep, with_instructions: with_instructions}
    end

    defp expect_result(result) do
      expect(Foundation.RpcMock, :call, fn :myelixir@host,
                                           :persistent_term,
                                           :get,
                                           [{:deployex, :jobs}, :undefined],
                                           _timeout ->
        result
      end)
    end

    test "keeps what happened to each instance with the relup", ctx do
      ctx.keep.(ctx.with_instructions)

      expect_result(
        {"0.2.0",
         [
           {Oban, ["default", "mailers"], :finished, :resumed},
           {MyElixir.Oban, ["default"], {:running, 2}, :failed}
         ]}
      )

      log = capture_log(fn -> assert :ok = Jobs.record(ctx.data) end)
      assert log =~ "Jobs of myelixir 0.1.0 -> 0.2.0: Oban paused 2 queues, no job was left"
      assert log =~ "MyElixir.Oban paused 1 queue, 2 jobs were still running after the wait"
      assert log =~ "NOT RESUMED"

      assert %{
               text: "relup",
               jobs: [
                 %{name: "Oban", queues: ["default", "mailers"], running: 0, resumed: "resumed"},
                 %{name: "MyElixir.Oban", queues: ["default"], running: 2, resumed: "failed"}
               ]
             } = Catalog.relup("myelixir", "0.1.0", "0.2.0")
    end

    test "keeps an empty list for an application without Oban", ctx do
      ctx.keep.(ctx.with_instructions)
      expect_result({"0.2.0", []})

      assert capture_log(fn -> assert :ok = Jobs.record(ctx.data) end) =~
               "no Oban queue was running"

      assert %{jobs: []} = Catalog.relup("myelixir", "0.1.0", "0.2.0")
    end

    test "does not ask the node when the relup has no instructions, or none was kept", ctx do
      assert :ok = Jobs.record(ctx.data)

      ctx.keep.([@load])
      assert :ok = Jobs.record(ctx.data)
      refute Map.has_key?(Catalog.relup("myelixir", "0.1.0", "0.2.0"), :jobs)
    end

    test "keeps nothing for a result that is not the one of this upgrade", ctx do
      ctx.keep.(ctx.with_instructions)

      for answer <- [:undefined, [], {"0.1.5", []}, {:badrpc, :nodedown}] do
        expect_result(answer)

        assert capture_log(fn -> assert :ok = Jobs.record(ctx.data) end) =~
                 "could not be recorded"

        refute Map.has_key?(Catalog.relup("myelixir", "0.1.0", "0.2.0"), :jobs)
      end
    end
  end
end
