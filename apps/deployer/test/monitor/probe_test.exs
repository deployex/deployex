defmodule Deployer.Monitor.ProbeTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  alias Deployer.Monitor.Probe
  alias Foundation.Yaml.Readiness

  @node :"myelixir-abc123@host"

  test "timeout is ready without asking the node" do
    expect(Foundation.RpcMock, :call, 0, fn _node, _module, _function, _args, _timeout -> nil end)

    assert Probe.ready?(%Readiness{type: :timeout}, @node, "elixir")
  end

  test "otp is ready when the boot of the node finished" do
    expect(Foundation.RpcMock, :call, fn @node, :init, :get_status, [], 1_000 ->
      {:started, :started}
    end)

    assert Probe.ready?(%Readiness{type: :otp}, @node, "elixir")
  end

  for status <- [
        {:starting, :applications_loaded},
        {:starting, :started},
        {:stopping, :started},
        {:badrpc, :nodedown},
        {:badrpc, :timeout}
      ] do
    test "otp is not ready when the node answers #{inspect(status)}" do
      expect(Foundation.RpcMock, :call, fn @node, :init, :get_status, [], 1_000 ->
        unquote(Macro.escape(status))
      end)

      refute Probe.ready?(%Readiness{type: :otp}, @node, "elixir")
    end
  end

  # Boots from -eval, which only returns when the application ends
  test "otp on gleam is ready while the node answers from its -eval" do
    expect(Foundation.RpcMock, :call, fn @node, :init, :get_status, [], 1_000 ->
      {:starting, :started}
    end)

    assert Probe.ready?(%Readiness{type: :otp}, @node, "gleam")
  end

  for status <- [{:stopping, :started}, {:badrpc, :nodedown}, {:badrpc, :timeout}] do
    test "otp on gleam is not ready when the node answers #{inspect(status)}" do
      expect(Foundation.RpcMock, :call, fn @node, :init, :get_status, [], 1_000 ->
        unquote(Macro.escape(status))
      end)

      refute Probe.ready?(%Readiness{type: :otp}, @node, "gleam")
    end
  end
end
