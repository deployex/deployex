defmodule Deployer.Status.EndpointsTest do
  use ExUnit.Case, async: false

  import Mox

  alias Deployer.Status.Endpoints

  setup [
    :set_mox_global,
    :verify_on_exit!
  ]

  @node :"myelixir-abc123@nohost"

  test "urls/1 returns the url of every registered endpoint module" do
    registered = [
      :init,
      :kernel_sup,
      :"Elixir.MyAppWeb.Endpoint",
      :"Elixir.MyAppWeb.Endpoint.Config",
      :"Elixir.MyApp.Repo"
    ]

    Foundation.RpcMock
    |> expect(:call, fn @node, :erlang, :registered, [], _timeout -> registered end)
    |> expect(:call, fn @node, :"Elixir.MyAppWeb.Endpoint", :url, [], _timeout ->
      "http://localhost:4000"
    end)
    |> expect(:call, fn @node, :"Elixir.MyAppWeb.Endpoint", :server_info, [:http], _timeout ->
      {:ok, {{127, 0, 0, 1}, 4000}}
    end)

    assert {:ok, ["http://localhost:4000"]} = Endpoints.urls(@node)
  end

  test "urls/1 returns every endpoint when the application serves more than one" do
    registered = [:"Elixir.MyAppWeb.Endpoint", :"Elixir.MyAppWeb.AdminEndpoint"]

    Foundation.RpcMock
    |> expect(:call, fn @node, :erlang, :registered, [], _timeout -> registered end)
    |> stub(:call, fn
      @node, :"Elixir.MyAppWeb.Endpoint", :url, [], _timeout ->
        "https://example.com"

      @node, :"Elixir.MyAppWeb.AdminEndpoint", :url, [], _timeout ->
        "http://localhost:4001"

      # One listens on https only, the other on http
      @node, :"Elixir.MyAppWeb.Endpoint", :server_info, [:http], _timeout ->
        {:error, :no_server_found}

      @node, :"Elixir.MyAppWeb.Endpoint", :server_info, [:https], _timeout ->
        {:ok, {{0, 0, 0, 0}, 443}}

      @node, :"Elixir.MyAppWeb.AdminEndpoint", :server_info, [:http], _timeout ->
        {:ok, {{127, 0, 0, 1}, 4001}}
    end)

    assert {:ok, ["http://localhost:4001", "https://example.com"]} = Endpoints.urls(@node)
  end

  test "urls/1 does not ask a name outside the endpoint convention for a url" do
    Foundation.RpcMock
    |> expect(:call, fn @node, :erlang, :registered, [], _timeout ->
      [:init, :kernel_sup, :"Elixir.MyApp.Repo", :"Elixir.MyAppWeb.Telemetry"]
    end)

    # verify_on_exit! fails the test if any of the names above is asked for a url
    assert {:ok, []} = Endpoints.urls(@node)
  end

  test "urls/1 discards a registered endpoint that does not export url/0" do
    Foundation.RpcMock
    |> expect(:call, fn @node, :erlang, :registered, [], _timeout ->
      [:"Elixir.MyApp.Endpoint"]
    end)
    |> expect(:call, fn @node, :"Elixir.MyApp.Endpoint", :url, [], _timeout ->
      {:badrpc, {:EXIT, {:undef, []}}}
    end)

    assert {:ok, []} = Endpoints.urls(@node)
  end

  test "urls/1 returns an error when the node is unreachable" do
    Foundation.RpcMock
    |> expect(:call, fn @node, :erlang, :registered, [], _timeout -> {:badrpc, :nodedown} end)

    assert :error = Endpoints.urls(@node)
  end

  test "urls/1 reports the same url once when two endpoints resolve to it" do
    registered = [:"Elixir.MyAppWeb.Endpoint", :"Elixir.MyAppWeb.OtherEndpoint"]

    Foundation.RpcMock
    |> expect(:call, fn @node, :erlang, :registered, [], _timeout -> registered end)
    |> stub(:call, fn
      @node, _module, :url, [], _timeout -> "http://localhost:4000"
      @node, _module, :server_info, [:http], _timeout -> {:ok, {{127, 0, 0, 1}, 4000}}
    end)

    assert {:ok, ["http://localhost:4000"]} = Endpoints.urls(@node)
  end

  test "urls/1 leaves out an endpoint that is registered and listens on nothing" do
    registered = [:"Elixir.MyAppWeb.Endpoint", :"Elixir.MyAppWeb.ApiEndpoint"]

    Foundation.RpcMock
    |> expect(:call, fn @node, :erlang, :registered, [], _timeout -> registered end)
    |> stub(:call, fn
      @node, :"Elixir.MyAppWeb.Endpoint", :url, [], _timeout ->
        "http://localhost:4000"

      @node, :"Elixir.MyAppWeb.ApiEndpoint", :url, [], _timeout ->
        "http://localhost:4002"

      @node, :"Elixir.MyAppWeb.Endpoint", :server_info, [:http], _timeout ->
        {:ok, {{127, 0, 0, 1}, 4000}}

      # Started without a server: it has a url, and no listener for either scheme
      @node, :"Elixir.MyAppWeb.ApiEndpoint", :server_info, [_scheme], _timeout ->
        {:error, :no_server_found}
    end)

    assert {:ok, ["http://localhost:4000"]} = Endpoints.urls(@node)
  end

  test "urls/1 keeps the url of an endpoint that cannot say whether it listens" do
    Foundation.RpcMock
    |> expect(:call, fn @node, :erlang, :registered, [], _timeout ->
      [:"Elixir.MyAppWeb.Endpoint"]
    end)
    |> stub(:call, fn
      @node, :"Elixir.MyAppWeb.Endpoint", :url, [], _timeout ->
        "http://localhost:4000"

      # A Phoenix without server_info/1
      @node, :"Elixir.MyAppWeb.Endpoint", :server_info, [:http], _timeout ->
        {:badrpc, {:EXIT, {:undef, []}}}
    end)

    assert {:ok, ["http://localhost:4000"]} = Endpoints.urls(@node)
  end
end
