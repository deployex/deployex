defmodule Deployer.Fleet do
  @moduledoc """
  What this DeployEx and the ones it is connected to are running: one summary a node, with
  its applications, the version of each instance, what it ghosted and the deployment locks
  it holds or waits for.

  Each DeployEx only knows its own host. `summaries/0` asks every connected one for its
  `node_summary/0`, so a dashboard can show them side by side: which host is on which
  version, and which one is deploying. See `Foundation.Peers` and `Deployer.Lock`.
  """

  alias Deployer.Lock
  alias Deployer.Status
  alias Foundation.Catalog
  alias Foundation.Peers

  @rpc_timeout 3_000

  @type instance :: %{
          sname: String.t() | nil,
          version: String.t() | nil,
          running?: boolean()
        }

  @type application :: %{
          name: String.t(),
          language: String.t(),
          instances: [instance()],
          ghosted: [String.t()]
        }

  @typedoc """
  `answers?` is false for a connected node that did not give its summary, one that runs a
  DeployEx without this module for instance. Its lists are then empty.
  """
  @type summary :: %{
          node: node(),
          host: String.t(),
          answers?: boolean(),
          deployex_version: String.t() | nil,
          applications: [application()],
          locks: [Lock.entry()]
        }

  @doc """
  The summary of this node.
  """
  @spec node_summary() :: summary()
  def node_summary do
    %{
      node: Node.self(),
      host: host(Node.self()),
      answers?: true,
      deployex_version: :deployer |> Application.spec(:vsn) |> to_string(),
      applications: applications(),
      locks: Lock.list()
    }
  end

  @doc """
  The summary of this node, then the one of each connected DeployEx, by host name.
  """
  @spec summaries() :: [summary()]
  def summaries do
    peers = Peers.list()

    remote =
      peers
      |> :erpc.multicall(__MODULE__, :node_summary, [], @rpc_timeout)
      |> Enum.zip(peers)
      |> Enum.map(fn
        {{:ok, %{node: _node} = summary}, _peer} -> summary
        {_no_answer, peer} -> no_answer(peer)
      end)

    [node_summary() | Enum.sort_by(remote, & &1.host)]
  end

  @doc """
  The applications that do not run one version everywhere, each with the versions found
  on the nodes of `summaries`.

  ## Examples

      iex> instance = fn version -> %{sname: "a-1", version: version, running?: true} end
      ...> node = fn version ->
      ...>   %{applications: [%{name: "myapp", instances: [instance.(version)]}]}
      ...> end
      ...> Deployer.Fleet.drift([node.("1.0.0"), node.("1.1.0"), node.("1.1.0")])
      [{"myapp", ["1.0.0", "1.1.0"]}]
      iex> Deployer.Fleet.drift([node.("1.1.0"), node.("1.1.0")])
      []
  """
  @spec drift([map()]) :: [{String.t(), [String.t()]}]
  def drift(summaries) do
    versions =
      for %{applications: applications} <- summaries,
          %{name: name, instances: instances} <- applications,
          %{version: version} when is_binary(version) <- instances,
          reduce: %{} do
        acc -> Map.update(acc, name, MapSet.new([version]), &MapSet.put(&1, version))
      end

    for {name, versions} <- Enum.sort(versions), MapSet.size(versions) > 1 do
      {name, Enum.sort(versions)}
    end
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp applications do
    names = Enum.map(Catalog.applications(), & &1.name)

    case Status.monitoring() do
      {:ok, statuses} ->
        for %{name: name} = status <- statuses, name in names do
          %{
            name: name,
            language: status.language,
            instances: Enum.map(status.children, &instance/1),
            ghosted: name |> Status.ghosted_version_list() |> Enum.map(& &1.version)
          }
        end

      _no_answer ->
        []
    end
  end

  defp instance(child) do
    %{
      sname: child.sname,
      version: child.version,
      running?:
        child.status == :running or (child.status == :pre_commands and child.otp == :connected)
    }
  end

  defp no_answer(node) do
    %{
      node: node,
      host: host(node),
      answers?: false,
      deployex_version: nil,
      applications: [],
      locks: []
    }
  end

  defp host(node), do: node |> Atom.to_string() |> String.split("@") |> List.last()
end
