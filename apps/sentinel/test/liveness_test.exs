defmodule Sentinel.LivenessTest do
  use ExUnit.Case, async: false

  import Mock
  import Mox

  alias Deployer.Monitor
  alias Foundation.Catalog
  alias Foundation.Notifications
  alias Foundation.Yaml.Liveness, as: LivenessConfig
  alias Foundation.Yaml.Ports
  alias Sentinel.Liveness

  @liveness_data :deployex_liveness_data

  setup [
    :set_mox_global,
    :verify_on_exit!
  ]

  @tag :capture_log
  test "start_link/1" do
    assert {:ok, _pid} = Liveness.start_link(liveness_check_interval: 10_000)
  end

  @tag :capture_log
  test "an application with no liveness section is not probed" do
    sname = Catalog.create_sname("myelixir")

    Deployer.MonitorMock
    |> stub(:list, fn -> [sname] end)
    |> stub(:state, fn ^sname ->
      %Monitor{status: :running, language: "elixir", name: "myelixir", liveness: nil}
    end)

    Foundation.RpcMock
    |> expect(:call, 0, fn _node, _module, _function, _args, _timeout -> nil end)

    assert {:ok, pid} = Liveness.start_link(liveness_check_interval: 10_000)

    tick(pid)
  end

  @tag :capture_log
  test "an instance that is not running yet is not probed, and is not counted as failing" do
    sname = Catalog.create_sname("myelixir")

    Deployer.MonitorMock
    |> stub(:list, fn -> [sname] end)
    |> stub(:state, fn ^sname ->
      %Monitor{
        status: :starting,
        language: "elixir",
        name: "myelixir",
        liveness: %LivenessConfig{
          type: :otp,
          period_ms: 0,
          failure_threshold: 1,
          enable_restart: false
        }
      }
    end)

    Foundation.RpcMock
    |> expect(:call, 0, fn _node, _module, _function, _args, _timeout -> nil end)

    assert {:ok, pid} = Liveness.start_link(liveness_check_interval: 10_000)

    tick(pid)

    assert [{^sname, %Liveness.Data{consecutive_failures: 0, notified: false}}] =
             :ets.lookup(@liveness_data, sname)
  end

  @tag :capture_log
  test "a probe that recovers before failure_threshold sends no notification" do
    sname = Catalog.create_sname("myelixir")
    %{node: node} = Catalog.node_info(sname)

    Phoenix.PubSub.subscribe(Foundation.PubSub, Notifications.topic("liveness_probe_failed"))

    Deployer.MonitorMock
    |> stub(:list, fn -> [sname] end)
    |> stub(:state, fn ^sname ->
      %Monitor{
        status: :running,
        language: "elixir",
        name: "myelixir",
        liveness: %LivenessConfig{
          type: :otp,
          period_ms: 0,
          failure_threshold: 3,
          enable_restart: false
        }
      }
    end)

    Foundation.RpcMock
    |> expect(:call, fn ^node, :init, :get_status, [], 1_000 -> {:badrpc, :nodedown} end)
    |> expect(:call, fn ^node, :init, :get_status, [], 1_000 -> {:badrpc, :nodedown} end)
    |> expect(:call, fn ^node, :init, :get_status, [], 1_000 -> {:started, :started} end)

    assert {:ok, pid} = Liveness.start_link(liveness_check_interval: 10_000)

    tick(pid)

    assert [{^sname, %Liveness.Data{consecutive_failures: 1}}] =
             :ets.lookup(@liveness_data, sname)

    tick(pid)

    assert [{^sname, %Liveness.Data{consecutive_failures: 2}}] =
             :ets.lookup(@liveness_data, sname)

    tick(pid)

    assert [{^sname, %Liveness.Data{consecutive_failures: 0, notified: false}}] =
             :ets.lookup(@liveness_data, sname)

    refute_receive {"liveness_probe_failed", _payload}
  end

  @tag :capture_log
  test "a hung application is detected after failure_threshold failed probes, notified once, and not restarted when enable_restart is false" do
    sname = Catalog.create_sname("myelixir")
    %{node: node} = Catalog.node_info(sname)

    Phoenix.PubSub.subscribe(Foundation.PubSub, Notifications.topic("liveness_probe_failed"))

    Deployer.MonitorMock
    |> stub(:list, fn -> [sname] end)
    |> stub(:state, fn ^sname ->
      %Monitor{
        status: :running,
        language: "elixir",
        name: "myelixir",
        liveness: %LivenessConfig{
          type: :otp,
          period_ms: 0,
          failure_threshold: 2,
          enable_restart: false
        }
      }
    end)
    |> expect(:restart, 0, fn _sname, _options -> :ok end)

    Foundation.RpcMock
    |> stub(:call, fn ^node, :init, :get_status, [], 1_000 -> {:badrpc, :nodedown} end)

    assert {:ok, pid} = Liveness.start_link(liveness_check_interval: 10_000)

    tick(pid)
    refute_receive {"liveness_probe_failed", _payload}

    tick(pid)

    assert_receive {"liveness_probe_failed",
                    %{
                      node: ^node,
                      sname: ^sname,
                      name: "myelixir",
                      consecutive_failures: 2,
                      failure_threshold: 2,
                      action: :no_restart
                    }}

    # A streak that stays hung is reported once, not on every tick
    tick(pid)
    refute_receive {"liveness_probe_failed", _payload}
  end

  @tag :capture_log
  test "restarts the application once failure_threshold is reached when enable_restart is true" do
    sname = Catalog.create_sname("myelixir")
    %{node: node} = Catalog.node_info(sname)

    Phoenix.PubSub.subscribe(Foundation.PubSub, Notifications.topic("liveness_probe_failed"))

    Deployer.MonitorMock
    |> stub(:list, fn -> [sname] end)
    |> stub(:state, fn ^sname ->
      %Monitor{
        status: :running,
        language: "elixir",
        name: "myelixir",
        liveness: %LivenessConfig{
          type: :otp,
          period_ms: 0,
          failure_threshold: 1,
          enable_restart: true
        }
      }
    end)
    |> expect(:restart, fn ^sname, options ->
      assert options[:cause] == :liveness
      :ok
    end)

    Foundation.RpcMock
    |> expect(:call, fn ^node, :init, :get_status, [], 1_000 -> {:badrpc, :nodedown} end)

    assert {:ok, pid} = Liveness.start_link(liveness_check_interval: 10_000)

    tick(pid)

    assert_receive {"liveness_probe_failed", %{action: :restart}}
  end

  @tag :capture_log
  test "an instance is probed again only after its period_ms" do
    sname = Catalog.create_sname("myelixir")
    %{node: node} = Catalog.node_info(sname)

    Deployer.MonitorMock
    |> stub(:list, fn -> [sname] end)
    |> stub(:state, fn ^sname ->
      %Monitor{
        status: :running,
        language: "elixir",
        name: "myelixir",
        liveness: %LivenessConfig{type: :otp, period_ms: 60_000, failure_threshold: 3}
      }
    end)

    Foundation.RpcMock
    |> expect(:call, 1, fn ^node, :init, :get_status, [], 1_000 -> {:badrpc, :nodedown} end)

    assert {:ok, pid} = Liveness.start_link(liveness_check_interval: 10_000)

    tick(pid)
    tick(pid)
    tick(pid)

    assert [{^sname, %Liveness.Data{consecutive_failures: 1}}] =
             :ets.lookup(@liveness_data, sname)
  end

  @tag :capture_log
  test "an http liveness requests the port of the instance and reports one that stops answering" do
    sname = Catalog.create_sname("myelixir")

    Phoenix.PubSub.subscribe(Foundation.PubSub, Notifications.topic("liveness_probe_failed"))

    Deployer.MonitorMock
    |> stub(:list, fn -> [sname] end)
    |> stub(:state, fn ^sname ->
      %Monitor{
        status: :running,
        language: "elixir",
        name: "myelixir",
        ports: [%Ports{key: "PORT", base: 4001}],
        liveness: %LivenessConfig{
          type: :http,
          period_ms: 0,
          failure_threshold: 2,
          port_key: "PORT",
          path: "/live"
        }
      }
    end)
    |> expect(:restart, 0, fn _sname, _options -> :ok end)

    Foundation.RpcMock
    |> expect(:call, 0, fn _node, _module, _function, _args, _timeout -> nil end)

    assert {:ok, pid} = Liveness.start_link(liveness_check_interval: 10_000)

    with_mock Deployer.Monitor.Probe.Http,
      get: fn "http://127.0.0.1:4001/live", 1_000 -> {:ok, 200} end do
      tick(pid)
    end

    assert [{^sname, %Liveness.Data{consecutive_failures: 0}}] =
             :ets.lookup(@liveness_data, sname)

    with_mock Deployer.Monitor.Probe.Http,
      get: fn "http://127.0.0.1:4001/live", 1_000 -> {:error, :timeout} end do
      tick(pid)
      tick(pid)
    end

    assert_receive {"liveness_probe_failed",
                    %{sname: ^sname, consecutive_failures: 2, action: :no_restart}}
  end

  # Fetching the state guarantees handle_info/2 ran to completion before the assertions
  defp tick(pid) do
    send(pid, :liveness_check)
    :sys.get_state(pid)
  end
end
