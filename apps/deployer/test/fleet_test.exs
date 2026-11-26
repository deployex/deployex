defmodule Deployer.FleetTest do
  use ExUnit.Case, async: false

  import Mox

  alias Deployer.Fleet
  alias Foundation.Catalog

  doctest Deployer.Fleet

  setup [:set_mox_global, :verify_on_exit!]

  defp stub_status(name) do
    Deployer.StatusMock
    |> stub(:monitoring, fn ->
      {:ok,
       [
         %Deployer.Status{name: "deployex", children: []},
         %Deployer.Status{
           name: name,
           language: "elixir",
           children: [
             %Deployer.Status{sname: "#{name}-abc123", version: "1.0.0", status: :running},
             %Deployer.Status{sname: "#{name}-def456", version: "1.1.0", status: :starting},
             %Deployer.Status{
               sname: "#{name}-ghi789",
               version: "1.1.0",
               status: :pre_commands,
               otp: :connected
             }
           ]
         }
       ]}
    end)
    |> stub(:ghosted_version_list, fn ^name -> [%Catalog.Version{version: "1.2.0"}] end)
  end

  test "node_summary/0 has the applications of this node, and not DeployEx itself" do
    [%{name: name} | _others] = Catalog.applications()
    stub_status(name)

    assert %{
             node: :nonode@nohost,
             host: "nohost",
             answers?: true,
             applications: [application],
             locks: locks
           } = summary = Fleet.node_summary()

    assert summary.deployex_version == to_string(Application.spec(:deployer, :vsn))
    assert is_list(locks)

    assert application == %{
             name: name,
             language: "elixir",
             ghosted: ["1.2.0"],
             instances: [
               %{sname: "#{name}-abc123", version: "1.0.0", running?: true},
               %{sname: "#{name}-def456", version: "1.1.0", running?: false},
               %{sname: "#{name}-ghi789", version: "1.1.0", running?: true}
             ]
           }
  end

  test "node_summary/0 has the locks of this node" do
    stub(Deployer.StatusMock, :monitoring, fn -> {:error, :rescued} end)
    name = "fleet-#{System.unique_integer([:positive])}"
    :ok = Deployer.Lock.acquire(name, %{to_version: "2.0.0"})

    assert %{applications: [], locks: locks} = Fleet.node_summary()
    assert [%{state: :held, to_version: "2.0.0"}] = Enum.filter(locks, &(&1.name == name))

    Deployer.Lock.release(name)
  end

  test "summaries/0 is this node when it is not connected to another DeployEx" do
    stub(Deployer.StatusMock, :monitoring, fn -> {:ok, []} end)

    assert [%{node: :nonode@nohost, applications: []}] = Fleet.summaries()
  end
end
