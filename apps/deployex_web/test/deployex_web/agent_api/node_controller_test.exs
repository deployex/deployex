defmodule DeployexWeb.AgentApi.NodeControllerTest do
  use DeployexWeb.AgentApiCase, async: false

  import Mock
  import Mox

  alias DeployexWeb.Fixture.Status, as: FixtureStatus

  setup [:set_mox_global, :verify_on_exit!]

  setup %{conn: conn} do
    put_api_tokens(token_entry("ci", "read", "read-token"))
    %{conn: bearer(conn, "read-token")}
  end

  test "GET /v1/node returns DeployEx and the host", %{conn: conn} do
    deployex =
      FixtureStatus.deployex(%{node: :deployex@host, otp_version: "29", elixir_version: "1.20.4"})

    stub(Deployer.StatusMock, :monitoring, fn ->
      {:ok, [deployex, FixtureStatus.application()]}
    end)

    host_info = %Host.Info{
      host: "Linux",
      description: "Ubuntu 24.04",
      uptime: "15 days",
      uptime_seconds: 1_296_000,
      cpu: 50.0,
      cpus: 2,
      memory_total: 2_000,
      memory_free: 500
    }

    with_mock Host.Info, latest: fn -> host_info end do
      assert conn |> get("/v1/node") |> json_response(200) == %{
               "node" => "deployex@host",
               "version" => "1.2.3",
               "started_at" => "2026-10-01T07:00:00Z",
               "otp_version" => "29",
               "elixir_version" => "1.20.4",
               "host" => %{
                 "os" => "Linux",
                 "description" => "Ubuntu 24.04",
                 "uptime_seconds" => 1_296_000,
                 "cpus" => 2,
                 "cpu_percent" => 25.0,
                 "memory_total" => 2_000,
                 "memory_free" => 500
               }
             }
    end
  end

  test "GET /v1/node returns no host before the first reading", %{conn: conn} do
    stub(Deployer.StatusMock, :monitoring, fn -> {:ok, FixtureStatus.list()} end)

    with_mock Host.Info, latest: fn -> nil end do
      assert %{"host" => nil, "version" => "1.2.3"} =
               conn |> get("/v1/node") |> json_response(200)
    end
  end

  test "GET /v1/node returns no cpu percent when the host reading has none", %{conn: conn} do
    stub(Deployer.StatusMock, :monitoring, fn -> {:ok, FixtureStatus.list()} end)

    with_mock Host.Info, latest: fn -> %Host.Info{host: "Windows"} end do
      assert %{"host" => %{"os" => "Windows", "cpu_percent" => nil}} =
               conn |> get("/v1/node") |> json_response(200)
    end
  end

  test "GET /v1/node returns 503 when the status server does not answer", %{conn: conn} do
    stub(Deployer.StatusMock, :monitoring, fn -> {:error, :rescued} end)

    assert conn |> get("/v1/node") |> json_response(503)
  end

  describe "the hot upgrades of DeployEx itself" do
    setup do
      relup = %{
        from_version: "1.2.2",
        to_version: "1.2.3",
        summary: %{
          applications: [{"deployer", "1.2.3"}, {"deployex_web", "1.2.3"}],
          modules: 5,
          updated: [],
          removed: [],
          applies: [],
          runtime_config: true,
          restart_emulator: false,
          instructions: 12
        },
        text: "{\"1.2.3\",[{\"1.2.2\",[],[point_of_no_return]}],[]}.\n",
        inserted_at: ~N[2026-11-23 10:00:00]
      }

      :ok = Foundation.Catalog.add_relup("deployex", relup)

      on_exit(fn ->
        File.rm_rf(
          Path.join([
            Application.fetch_env!(:foundation, :var_path),
            "storage",
            "deployex",
            "deployex",
            "relup"
          ])
        )
      end)

      :ok
    end

    test "GET /v1/node/versions returns them, with the version each one started from", %{
      conn: conn
    } do
      stub(Deployer.StatusMock, :history_version_list, fn "deployex", [] ->
        [
          FixtureStatus.version(%{
            version: "1.2.3",
            name: "deployex",
            sname: "deployex",
            deployment: :hot_upgrade,
            from_version: "1.2.2"
          }),
          # Recorded by a version without the field
          %{
            version: "1.2.2",
            name: "deployex",
            sname: "deployex",
            deployment: :hot_upgrade
          }
          |> FixtureStatus.version()
          |> Map.delete(:from_version)
        ]
      end)

      assert %{
               "versions" => [
                 %{
                   "version" => "1.2.3",
                   "from_version" => "1.2.2",
                   "deployment" => "hot_upgrade"
                 },
                 %{"version" => "1.2.2", "from_version" => nil}
               ]
             } = conn |> get("/v1/node/versions") |> json_response(200)
    end

    test "GET /v1/node/relups/:from_version/:to_version returns the relup that was kept", %{
      conn: conn
    } do
      assert %{
               "from_version" => "1.2.2",
               "to_version" => "1.2.3",
               "inserted_at" => "2026-11-23T10:00:00Z",
               "summary" => %{
                 "applications" => [
                   %{"name" => "deployer", "version" => "1.2.3"},
                   %{"name" => "deployex_web", "version" => "1.2.3"}
                 ],
                 "modules" => 5,
                 "runtime_config" => true
               },
               "relup" => "{\"1.2.3\"" <> _script
             } = conn |> get("/v1/node/relups/1.2.2/1.2.3") |> json_response(200)
    end

    test "GET /v1/node/relups returns 404 for an upgrade that has no relup, or a version that is not one",
         %{conn: conn} do
      assert conn |> get("/v1/node/relups/1.2.1/1.2.2") |> json_response(404)
      assert conn |> get("/v1/node/relups/..%2F..%2Fetc/1.2.3") |> json_response(404)
    end
  end
end
