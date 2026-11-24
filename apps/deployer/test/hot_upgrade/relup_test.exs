defmodule Deployer.HotUpgrade.RelupTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Deployer.HotUpgrade.Execute
  alias Deployer.HotUpgrade.Relup
  alias Foundation.Catalog
  alias Foundation.Fixture.Catalog, as: FixtureCatalog

  doctest Deployer.HotUpgrade.Relup

  # What DeployEx puts at the head of the script, see install_runtime_config_hook/2
  @runtime_config_hook {:apply, {:erl_eval, :exprs, [[{:atom, 0, :ok}], []]}}

  @up_script [
    @runtime_config_hook,
    {:load_object_code, {:myelixir, ~c"0.2.0", [MyElixir.Worker, MyElixir.Web, MyElixir.Old]}},
    {:load_object_code, {:finch, ~c"0.25.0", [Finch.Pool]}},
    :point_of_no_return,
    {:suspend, [MyElixir.Worker]},
    {:load, {MyElixir.Worker, :brutal_purge, :brutal_purge}},
    {:code_change, :up, [{MyElixir.Worker, []}]},
    {:resume, [MyElixir.Worker]},
    {:load, {MyElixir.Web, :brutal_purge, :brutal_purge}},
    {:remove, {MyElixir.Old, :brutal_purge, :brutal_purge}},
    {:purge, [MyElixir.Old]},
    {:apply, {:supervisor, :restart_child, [MyElixir.Supervisor, Finch]}}
  ]

  @down_script [{:load_object_code, {:myelixir, ~c"0.1.0", [MyElixir.Worker]}}]

  setup do
    FixtureCatalog.cleanup()

    name = "myelixir"
    sname = Catalog.create_sname(name)
    Catalog.setup_new_node(sname)
    current_path = Catalog.current_path(sname)

    data = %Execute{
      name: name,
      sname: sname,
      current_path: current_path,
      from_version: ~c"0.1.0",
      to_version: ~c"0.2.0"
    }

    %{name: name, data: data, relup_path: "#{current_path}/releases/0.2.0/relup"}
  end

  defp write_relup!(path, relup) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [relup]))
  end

  test "save/1 keeps the upgrade that is about to be installed, with its summary", %{
    name: name,
    data: data,
    relup_path: relup_path
  } do
    write_relup!(
      relup_path,
      {~c"0.2.0", [{~c"0.1.0", [], @up_script}], [{~c"0.1.0", [], @down_script}]}
    )

    assert :ok = Relup.save(data)

    assert %{from_version: "0.1.0", to_version: "0.2.0", summary: summary, text: text} =
             Catalog.relup(name, "0.1.0", "0.2.0")

    assert summary == %{
             applications: [{"myelixir", "0.2.0"}, {"finch", "0.25.0"}],
             modules: 4,
             updated: ["MyElixir.Worker"],
             removed: ["MyElixir.Old"],
             applies: ["supervisor.restart_child/2"],
             runtime_config: true,
             version_update: false,
             pipelines: false,
             jobs: false,
             restart_emulator: false,
             instructions: 12
           }

    # The text is a relup with the upgrade only, DeployEx never applies the way back
    assert {:ok, tokens, _line} = text |> String.to_charlist() |> :erl_scan.string()
    assert {:ok, {~c"0.2.0", [{~c"0.1.0", [], script}], []}} = :erl_parse.parse_term(tokens)
    assert script == @up_script
  end

  test "save/1 keeps the script of the version the node runs when the relup has several", %{
    name: name,
    data: data,
    relup_path: relup_path
  } do
    write_relup!(
      relup_path,
      {~c"0.2.0",
       [
         {~c"0.0.9", [], [:restart_new_emulator]},
         {~c"0.1.0", [], [{:load_object_code, {:myelixir, ~c"0.2.0", [MyElixir.Web]}}]}
       ], []}
    )

    assert :ok = Relup.save(data)

    assert %{summary: %{modules: 1, restart_emulator: false, runtime_config: false}} =
             Catalog.relup(name, "0.1.0", "0.2.0")
  end

  test "save/1 never fails the upgrade", %{name: name, data: data, relup_path: relup_path} do
    # No relup on disk
    assert capture_log(fn -> assert :ok = Relup.save(data) end) =~
             "Could not keep the relup of myelixir 0.1.0 -> 0.2.0"

    # A relup that does not upgrade from the version the node runs
    write_relup!(relup_path, {~c"0.2.0", [{~c"0.0.9", [], []}], []})

    assert capture_log(fn -> assert :ok = Relup.save(data) end) =~ "no_script_from"

    # A version that cannot name a file
    write_relup!(relup_path, {~c"0.2.0", [{~c"../0.1.0", [], []}], []})

    assert capture_log(fn ->
             assert :ok = Relup.save(%{data | from_version: ~c"../0.1.0"})
           end) =~ "invalid_relup_name"

    assert Catalog.relup(name, "0.1.0", "0.2.0") == nil

    # An instruction that is not shaped as the summary expects raises while it is counted
    write_relup!(
      relup_path,
      {~c"0.2.0", [{~c"0.1.0", [], [{:code_change, :up, [:not_a_tuple]}]}], []}
    )

    assert capture_log(fn -> assert :ok = Relup.save(data) end) =~
             "Could not keep the relup of myelixir 0.1.0 -> 0.2.0"

    assert Catalog.relup(name, "0.1.0", "0.2.0") == nil

    # Upgrade data without the application or its path has nothing to read
    assert :ok = Relup.save(%Execute{})
  end

  test "summary/1 reports a restart of the VM" do
    assert %{restart_emulator: true, instructions: 1} = Relup.summary([:restart_new_emulator])
  end
end
