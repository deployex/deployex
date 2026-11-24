defmodule Deployer.HotUpgrade.ProtocolsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Deployer.HotUpgrade.Execute
  alias Deployer.HotUpgrade.Jobs
  alias Deployer.HotUpgrade.Pipelines
  alias Deployer.HotUpgrade.Protocols
  alias Deployer.HotUpgrade.Relup
  alias Deployer.HotUpgrade.VersionUpdate
  alias Foundation.Catalog
  alias Foundation.Fixture.Catalog, as: FixtureCatalog

  doctest Deployer.HotUpgrade.Protocols

  setup :verify_on_exit!

  @result_key {:deployex, :protocols}

  @load {:load, {MyElixir.Web, :brutal_purge, :brutal_purge}}
  @up_script [
    {:load_object_code, {:myelixir, ~c"0.2.0", [MyElixir.Web]}},
    :point_of_no_return,
    @load
  ]

  setup do
    path = :code.get_path()

    on_exit(fn ->
      :persistent_term.erase(@result_key)
      true = :code.set_path(path)
    end)

    root = Path.join(System.tmp_dir!(), "protocols-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    data = %Execute{
      name: "myelixir",
      node: :myelixir@host,
      current_path: root,
      from_version: ~c"0.1.0",
      to_version: ~c"0.2.0"
    }

    %{data: data, root: root, relup_path: "#{root}/releases/0.2.0/relup"}
  end

  defp write_relup!(path, relup) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [relup]))
  end

  defp run({:apply, {:erl_eval, :exprs, [forms, bindings]}}) do
    {:value, :ok, _bindings} = :erl_eval.exprs(forms, bindings)
    :persistent_term.get(@result_key, :nothing)
  end

  # A module as a consolidated protocol is to the instruction: one that is loaded, and
  # that the release has another build of
  defp compile!(module, answer) do
    source = "-module(#{module}).\n-export([answer/0]).\nanswer() -> #{answer}.\n"
    {:ok, tokens, _end} = :erl_scan.string(String.to_charlist(source))

    forms =
      tokens
      |> Enum.chunk_while(
        [],
        fn token, acc ->
          if elem(token, 0) == :dot,
            do: {:cont, Enum.reverse([token | acc]), []},
            else: {:cont, [token | acc]}
        end,
        fn acc -> {:cont, acc} end
      )
      |> Enum.map(fn form_tokens ->
        {:ok, form} = :erl_parse.parse_form(form_tokens)
        form
      end)

    {:ok, ^module, beam} = :compile.forms(forms)
    beam
  end

  defp load!(module, answer) do
    :code.purge(module)
    {:module, ^module} = :code.load_binary(module, ~c"#{module}.erl", compile!(module, answer))

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)
  end

  defp consolidated!(root, version, modules) do
    dir = Path.join([root, "releases", version, "consolidated"])
    File.mkdir_p!(dir)

    for {module, answer} <- modules,
        do: File.write!("#{dir}/#{module}.beam", compile!(module, answer))

    dir
  end

  describe "add_to_relup/1" do
    test "goes after the code is loaded, and before the work is started again", %{
      data: data,
      root: root,
      relup_path: relup_path
    } do
      write_relup!(
        relup_path,
        {~c"0.2.0", [{~c"0.0.9", [], @up_script}, {~c"0.1.0", [], @up_script}], []}
      )

      # In the order prepare_release/1 adds them
      assert :ok = Protocols.add_to_relup(data)
      assert :ok = VersionUpdate.add_to_relup(data)
      assert :ok = Pipelines.add_to_relup(data)
      assert :ok = Jobs.add_to_relup(data)

      assert {:ok, [{~c"0.2.0", [{~c"0.0.9", [], other}, {~c"0.1.0", [], script}], []}]} =
               :file.consult(relup_path)

      assert other == @up_script

      assert [
               {:load_object_code, _},
               :point_of_no_return,
               _jobs_pause,
               _pipelines_stop,
               @load,
               protocols,
               version_update,
               _pipelines_start,
               _jobs_resume
             ] = script

      assert protocols == Protocols.instruction(root, "0.2.0")
      assert Protocols.instruction?(protocols)
      refute Protocols.instruction?(version_update)
      refute VersionUpdate.instruction?(protocols)
      assert Pipelines.phase(protocols) == nil
      assert Jobs.phase(protocols) == nil

      assert %{protocols: true, version_update: true, pipelines: true, jobs: true, applies: []} =
               Relup.summary(script)

      assert %{key: :protocols, instruction: "apply"} =
               step = Enum.find(Relup.steps(script), &(&1.key == :protocols))

      assert Relup.explain(step) =~ "Loads the consolidated protocols"
      assert %{protocols: false} = Relup.summary(@up_script)
    end

    test "leaves a script that restarts the VM as it is", %{data: data, relup_path: relup_path} do
      for script <- [[:restart_new_emulator | @up_script], @up_script ++ [:restart_emulator]] do
        write_relup!(relup_path, {~c"0.2.0", [{~c"0.1.0", [], script}], []})

        assert :ok = Protocols.add_to_relup(data)
        assert {:ok, [{~c"0.2.0", [{~c"0.1.0", [], ^script}], []}]} = :file.consult(relup_path)
      end
    end

    test "never fails the upgrade", %{data: data, relup_path: relup_path} do
      assert capture_log(fn -> assert :ok = Protocols.add_to_relup(data) end) =~
               "Protocol instruction not added to the relup"

      write_relup!(relup_path, :not_a_relup)

      assert capture_log(fn -> assert :ok = Protocols.add_to_relup(data) end) =~
               "Protocol instruction not added to the relup"

      assert :ok = Protocols.add_to_relup(%Execute{})
    end
  end

  describe "the instruction" do
    test "loads the protocols whose consolidated code changed, and only those", %{root: root} do
      load!(:deployex_changed_protocol, "previous")
      load!(:deployex_same_protocol, "same")

      dir =
        consolidated!(root, "0.2.0",
          deployex_changed_protocol: "updated",
          deployex_same_protocol: "same",
          deployex_new_protocol: "new"
        )

      # The directory of the release the node booted from, as it is on the code path
      old = consolidated!(root, "0.1.0", [])
      true = :code.add_patha(String.to_charlist(old))

      assert {"0.2.0", [deployex_changed_protocol: :reloaded, deployex_new_protocol: :reloaded]} =
               run(Protocols.instruction(root, "0.2.0"))

      assert :deployex_changed_protocol.answer() == :updated
      assert :deployex_same_protocol.answer() == :same
      assert :deployex_new_protocol.answer() == :new

      on_exit(fn ->
        :code.purge(:deployex_new_protocol)
        :code.delete(:deployex_new_protocol)
      end)

      # The code path follows the release
      assert hd(:code.get_path()) == String.to_charlist(dir)
      refute String.to_charlist(old) in :code.get_path()

      # Running it again finds nothing to load
      assert {"0.2.0", []} = run(Protocols.instruction(root, "0.2.0"))
    end

    test "goes on after a protocol that cannot be loaded", %{root: root} do
      load!(:deployex_changed_protocol, "previous")

      dir = consolidated!(root, "0.2.0", deployex_changed_protocol: "updated")
      File.write!("#{dir}/deployex_broken_protocol.beam", "not a beam")

      assert {"0.2.0", [deployex_broken_protocol: :failed, deployex_changed_protocol: :reloaded]} =
               run(Protocols.instruction(root, "0.2.0"))

      assert :deployex_changed_protocol.answer() == :updated
    end

    test "does nothing for a release without consolidated protocols", %{root: root} do
      path = :code.get_path()

      assert {"0.2.0", :none} = run(Protocols.instruction(root, "0.2.0"))
      assert :code.get_path() == path
    end
  end

  describe "record/1" do
    setup %{data: data, root: root} do
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

      %{data: data, keep: keep, with_instruction: [@load, Protocols.instruction(root, "0.2.0")]}
    end

    defp expect_result(result) do
      expect(Foundation.RpcMock, :call, fn :myelixir@host,
                                           :persistent_term,
                                           :get,
                                           [{:deployex, :protocols}, :undefined],
                                           _timeout ->
        result
      end)
    end

    test "keeps which protocols were loaded with the relup", ctx do
      ctx.keep.(ctx.with_instruction)

      for {on_node, kept, sentence} <- [
            {[{Jason.Encoder, :reloaded}, {String.Chars, :reloaded}, {Phoenix.Param, :failed}],
             %{
               reloaded: ["Jason.Encoder", "String.Chars"],
               failed: ["Phoenix.Param"],
               consolidated: true
             }, "2 consolidated protocols loaded: Jason.Encoder, String.Chars, and NOT LOADED"},
            {[], %{reloaded: [], failed: [], consolidated: true},
             "no consolidated protocol changed"},
            {:none, %{reloaded: [], failed: [], consolidated: false},
             "the release has no consolidated protocols"}
          ] do
        expect_result({"0.2.0", on_node})

        assert capture_log(fn -> assert :ok = Protocols.record(ctx.data) end) =~
                 "Protocols of myelixir 0.1.0 -> 0.2.0: #{sentence}"

        assert %{protocols: ^kept, text: "relup"} = Catalog.relup("myelixir", "0.1.0", "0.2.0")
      end
    end

    test "does not ask the node when the relup has no instruction, or none was kept", ctx do
      assert :ok = Protocols.record(ctx.data)

      ctx.keep.([@load])
      assert :ok = Protocols.record(ctx.data)
      refute Map.has_key?(Catalog.relup("myelixir", "0.1.0", "0.2.0"), :protocols)
    end

    test "keeps nothing for a result that is not the one of this upgrade", ctx do
      ctx.keep.(ctx.with_instruction)

      for answer <- [:undefined, {"0.1.5", []}, {:badrpc, :nodedown}] do
        expect_result(answer)

        assert capture_log(fn -> assert :ok = Protocols.record(ctx.data) end) =~
                 "could not be recorded"

        refute Map.has_key?(Catalog.relup("myelixir", "0.1.0", "0.2.0"), :protocols)
      end
    end
  end
end
