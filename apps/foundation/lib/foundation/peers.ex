defmodule Foundation.Peers do
  @moduledoc """
  Finds the other DeployEx nodes and connects to them.

  A DeployEx runs by itself on its host. Where there is one for each of several hosts, the
  pods of a Kubernetes StatefulSet for instance, `peers_dns_query` in the YAML names a DNS
  record that resolves to the address of each one. Every five seconds this server resolves
  it and connects to the DeployEx of every address it is not connected to yet.

  The applications need nothing for it. A DeployEx is connected to the applications it runs,
  and the OTP distribution connects every node to the nodes its peers know, so the
  applications of two DeployEx that are connected find each other, and so does the new
  instance of a full deployment.

  ## The name of a peer

  Every DeployEx has the same name before the `@`, the one of this node. What is after it
  depends on how the node is named:

    * **Short names**, which DeployEx uses - the first label of the host name the address
      resolves back to. `10.244.0.14`, which resolves to
      `dx-1.dx.default.svc.cluster.local`, is `deployex@dx-1`. That name has to resolve from
      the other hosts too, see the YAML guide. An address can resolve back to several
      names, the pod of a Kubernetes Service that is not the one of the query for instance.
      The one under the name of the query is taken, and the first one when none is.
    * **Long names**, with which DeployEx is started when `DEPLOYEX_NODE_HOST` is set - the
      address itself, `deployex@10.244.0.14`.

  The server is not started when `peers_dns_query` is not set.
  """

  use GenServer

  require Logger

  @interval :timer.seconds(5)

  defmodule Resolver do
    @moduledoc """
    What `Foundation.Peers` asks of the network, in one place so a test can answer for it.
    """

    @callback lookup(query :: String.t()) :: [:inet.ip_address()]
    @callback host_names(address :: :inet.ip_address()) :: [String.t()]
    @callback long_names?() :: boolean()
    @callback connect(node()) :: boolean() | :ignored
    @callback connected() :: [node()]

    @behaviour __MODULE__

    @impl true
    def lookup(query) do
      Enum.flat_map([:a, :aaaa], fn type ->
        case :inet_res.getbyname(String.to_charlist(query), type) do
          {:ok, {:hostent, _name, _aliases, _type, _length, addresses}} -> addresses
          {:error, _reason} -> []
        end
      end)
    end

    # Every name the address resolves back to. :inet_res.gethostbyaddr/1 answers with an
    # error when there is more than one, which is the case of a Kubernetes pod that is
    # behind a second Service, so the PTR records are asked for themselves
    @impl true
    def host_names(address) do
      address |> :inet_res.lookup(:in, :ptr) |> Enum.map(&to_string/1)
    end

    @impl true
    def long_names?, do: :net_kernel.longnames() == true

    @impl true
    def connect(node), do: Node.connect(node)

    @impl true
    def connected, do: Node.list()
  end

  ### ==========================================================================
  ### Public APIs
  ### ==========================================================================

  @doc """
  Starts the server. It is ignored when no DNS query is given or configured.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc """
  The DeployEx nodes this one is connected to, however they were connected.

  They are the connected nodes with the name of this one before the `@`.

  ## Examples

      iex> Foundation.Peers.list()
      []
  """
  @spec list() :: [node()]
  def list,
    do: Enum.sort(for(node <- Node.list(), base_name(node) == base_name(Node.self()), do: node))

  @doc """
  The node name of the DeployEx at `address`, or `nil` when the address does not resolve
  back to a host name and the nodes have short names.

  `query` is the DNS name the address came from. Of several host names of the address, the
  one under it is the name of the peer.

  ## Examples

      iex> Foundation.Peers.node_name("deployex", {10, 244, 0, 14}, Foundation.Peers.Resolver, true, "dx")
      :"deployex@10.244.0.14"
  """
  @spec node_name(String.t(), :inet.ip_address(), module(), boolean(), String.t()) ::
          node() | nil
  def node_name(base_name, address, _resolver, true = _long_names?, _query),
    do: :"#{base_name}@#{:inet.ntoa(address)}"

  def node_name(base_name, address, resolver, false = _long_names?, query) do
    host_names = address |> resolver.host_names() |> Enum.map(&normalize/1)
    domain = "." <> normalize(query)

    case Enum.find(host_names, List.first(host_names), &String.ends_with?(&1, domain)) do
      nil -> nil
      host_name -> :"#{base_name}@#{host_name |> String.split(".") |> hd()}"
    end
  end

  ### ==========================================================================
  ### GenServer callbacks
  ### ==========================================================================

  @impl true
  def init(options) do
    query = Keyword.get(options, :query, Application.get_env(:foundation, :peers_dns_query))

    if is_binary(query) and query != "" do
      Logger.info("Looking for other DeployEx nodes at: #{query}")

      state = %{
        query: query,
        resolver: Keyword.get(options, :resolver, Resolver),
        interval: Keyword.get(options, :interval, @interval),
        base_name: base_name(Node.self()),
        not_connecting: MapSet.new()
      }

      {:ok, state, {:continue, :discover}}
    else
      :ignore
    end
  end

  @impl true
  def handle_continue(:discover, state), do: {:noreply, discover(state)}

  @impl true
  def handle_info(:discover, state), do: {:noreply, discover(state)}

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp discover(%{resolver: resolver} = state) do
    connected = resolver.connected()
    long_names? = resolver.long_names?()

    peers =
      state.query
      |> resolver.lookup()
      |> Enum.map(&node_name(state.base_name, &1, resolver, long_names?, state.query))
      |> Enum.reject(&(is_nil(&1) or &1 == Node.self() or &1 in connected))
      |> Enum.uniq()

    not_connecting = Enum.reduce(peers, state.not_connecting, &connect(&1, resolver, &2))

    Process.send_after(self(), :discover, state.interval)
    # A peer that is gone from the DNS is forgotten, so it is reported again if it comes back
    %{state | not_connecting: MapSet.intersection(not_connecting, MapSet.new(peers))}
  end

  # A peer that does not connect is reported once, not every time it is tried
  defp connect(node, resolver, not_connecting) do
    if resolver.connect(node) == true do
      Logger.info("Connected to the DeployEx node: #{node}")
      MapSet.delete(not_connecting, node)
    else
      if node not in not_connecting do
        Logger.warning("The DeployEx node: #{node} does not connect, it is tried again")
      end

      MapSet.put(not_connecting, node)
    end
  end

  defp base_name(node), do: node |> Atom.to_string() |> String.split("@") |> hd()

  # A DNS name is not case sensitive, and may end with the dot of the root
  defp normalize(name), do: name |> String.downcase() |> String.trim_trailing(".")
end
