defmodule Foundation.PeersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Foundation.Peers

  doctest Foundation.Peers

  # Answers for the network. The test process is told every node that is tried.
  defmodule Network do
    @behaviour Foundation.Peers.Resolver

    def set(values), do: :persistent_term.put(__MODULE__, Map.new(values))
    defp get(key), do: Map.fetch!(:persistent_term.get(__MODULE__), key)

    @impl true
    def lookup(_query), do: get(:addresses)

    @impl true
    def host_names(address), do: Map.get(get(:host_names), address, [])

    @impl true
    def long_names?, do: get(:long_names?)

    @impl true
    def connect(node) do
      send(get(:test), {:tried, node})
      node in get(:connecting)
    end

    @impl true
    def connected, do: get(:connected)
  end

  @own :nonode@nohost
  @own_address {10, 244, 0, 13}
  @peer_address {10, 244, 0, 14}

  defp network(values) do
    Network.set(
      Keyword.merge(
        [
          test: self(),
          addresses: [@own_address, @peer_address],
          host_names: %{
            @own_address => ["nohost.dx.default.svc.cluster.local"],
            @peer_address => ["dx-1.dx.default.svc.cluster.local"]
          },
          long_names?: false,
          connecting: [:"nonode@dx-1"],
          connected: []
        ],
        values
      )
    )
  end

  defp start(options \\ []) do
    start_supervised!(
      {Peers,
       Keyword.merge([name: :peers_test, query: "dx", resolver: Network, interval: 20], options)}
    )
  end

  test "is not started without a DNS query" do
    assert Peers.start_link(name: :peers_no_query, query: nil) == :ignore
    assert Peers.start_link(name: :peers_no_query, query: "") == :ignore
  end

  test "connects to the DeployEx of each address, by its short host name" do
    network([])

    log = capture_log(fn -> start() && assert_receive({:tried, :"nonode@dx-1"}) end)

    assert log =~ "Connected to the DeployEx node: nonode@dx-1"
    assert Node.self() == @own
    refute_received {:tried, @own}
  end

  test "names the peer after its address when the nodes have long names" do
    network(long_names?: true, connecting: [])

    capture_log(fn -> start() && assert_receive({:tried, :"nonode@10.244.0.14"}) end)
  end

  test "does not try a node that is connected" do
    network(connected: [:"nonode@dx-1"])
    start()

    refute_receive {:tried, _node}, 100
  end

  test "skips an address that does not resolve back to a host name" do
    network(host_names: %{@own_address => ["nohost"]})
    start()

    refute_receive {:tried, _node}, 100
  end

  test "takes the host name under the DNS query when the address has several" do
    # A pod behind a second Kubernetes Service resolves back to a name in each
    network(
      host_names: %{
        @own_address => ["nohost.dx.default.svc.cluster.local"],
        @peer_address => [
          "10-244-0-14.dx-dashboard.default.svc.cluster.local",
          "DX-1.dx.default.svc.cluster.local."
        ]
      }
    )

    capture_log(fn ->
      start(query: "dx.default.svc.cluster.local")
      assert_receive {:tried, :"nonode@dx-1"}
    end)

    refute_received {:tried, :"nonode@10-244-0-14"}
  end

  test "takes the first host name when none is under the DNS query" do
    network(host_names: %{@peer_address => ["dx-1.hosts.internal", "other.hosts.internal"]})

    capture_log(fn -> start() && assert_receive({:tried, :"nonode@dx-1"}) end)
  end

  test "tries a peer that does not connect again, and reports it once" do
    network(connecting: [])

    log =
      capture_log(fn ->
        start()
        assert_receive {:tried, :"nonode@dx-1"}
        assert_receive {:tried, :"nonode@dx-1"}
        assert_receive {:tried, :"nonode@dx-1"}
      end)

    assert log |> String.split("does not connect") |> length() == 2
  end

  test "list/0 has no peer on a node that is alone" do
    assert Peers.list() == []
  end
end
