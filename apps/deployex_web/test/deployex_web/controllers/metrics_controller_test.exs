defmodule DeployexWeb.MetricsControllerTest do
  use DeployexWeb.ConnCase, async: true

  describe "show/2" do
    test "returns the Prometheus exposition format with the correct content type", %{conn: conn} do
      conn = get(conn, ~p"/metrics")

      assert {"content-type", "text/plain; version=0.0.4; charset=utf-8"} in conn.resp_headers
      assert conn.status == 200
    end

    test "scrapes a VM gauge, once :telemetry_poller has measured it at least once", %{
      conn: conn
    } do
      # The real measurement comes from :telemetry_poller's own default poller, every few
      # seconds. Emitting it here keeps the test from depending on that timing
      :telemetry.execute([:vm, :memory], %{total: 123_456_789}, %{})

      conn = get(conn, ~p"/metrics")

      assert conn.resp_body =~ "vm_memory_total_bytes 123456789"
    end

    test "scrapes a request after it is made, as a Prometheus histogram", %{conn: conn} do
      get(conn, ~p"/health")

      conn = get(conn, ~p"/metrics")

      assert conn.resp_body =~ "phoenix_router_dispatch_stop_duration_seconds_bucket"
      assert conn.resp_body =~ ~s(route="/health")
    end
  end
end
