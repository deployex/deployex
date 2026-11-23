defmodule DeployexWeb.Applications.VersionsTest do
  use DeployexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Deployer.HotUpgrade.Relup
  alias DeployexWeb.Fixture.Status, as: FixtureStatus
  alias DeployexWeb.HostTime
  alias Foundation.Catalog

  setup [:set_mox_global, :verify_on_exit!, :log_in_default_user]

  @name "myphoenixapp"
  @sname "myphoenixapp-abc123"

  defp version(version, deployment, inserted_at) do
    %Catalog.Version{
      version: version,
      name: @name,
      sname: @sname,
      deployment: deployment,
      inserted_at: inserted_at
    }
  end

  defp stub_status(config, test_pid \\ self()) do
    Deployer.StatusMock
    |> stub(:monitoring, fn ->
      app =
        %{name: @name, version: "1.4.2"}
        |> FixtureStatus.application(config)
        |> Map.merge(%{deploy_schedule_interval_ms: 5_000, deploy_rollback_timeout_ms: 600_000})

      {:ok, [FixtureStatus.deployex(), app]}
    end)
    |> stub(:subscribe, fn -> :ok end)
    |> stub(:history_version_list, fn @name, [] ->
      [
        %{
          version("1.4.2", :hot_upgrade, ~N[2026-10-28 12:14:00])
          | hot_upgrade_config_change: true,
            from_version: "1.4.1"
        },
        # A record written by a version without the field
        "1.4.1"
        |> version(:full_deployment, ~N[2026-10-25 09:02:00])
        |> Map.delete(:hot_upgrade_config_change)
      ]
    end)
    |> stub(:set_mode, fn @name, mode, version ->
      send(test_pid, {:set_mode, mode, version})
      {:ok, %{}}
    end)
  end

  defp config(mode \\ :automatic, manual_version \\ nil) do
    %{
      last_ghosted_version: "-/-",
      mode: mode,
      manual_version: manual_version,
      versions: ["1.4.2", "1.4.1", "1.4.0"]
    }
  end

  @tag :capture_log
  test "shows the mode and the version history of an app", %{conn: conn} do
    stub_status(config())

    {:ok, _view, html} = live(conn, ~p"/applications/#{@name}/versions")

    assert html =~ "Versions and mode · 1 instance · current 1.4.2"
    assert html =~ "Automatic"
    assert html =~ "DeployEx deploys the version that current.json names in the release bucket."

    assert html =~
             "DeployEx checks for a new version every 5 seconds. A new version that is not running within 10 minutes is ghosted"

    assert html =~ HostTime.format(~U[2026-10-28 12:14:00Z], "%Y-%m-%d %H:%M")
    assert html =~ "Deployed, host time #{HostTime.zone()}"
    assert html =~ "Hot upgrade"
    # What each release asked for in current.json
    assert html =~ "config_change"
    assert [_asked] = Regex.scan(~r/>\s*requested\s*</, html)
    assert [_unset] = Regex.scan(~r/>\s*not set\s*</, html)
    assert html =~ HostTime.format(~U[2026-10-25 09:02:00Z], "%Y-%m-%d %H:%M")
    assert [_current] = Regex.scan(~r/>current</, html)
    assert html =~ "This host keeps the releases of the last 2 versions."
    assert html =~ ~s(href="/applications/#{@name}/ghosted")
    refute html =~ ~s(id="mode-save")
  end

  @tag :capture_log
  test "a hot upgrade shows the relup DeployEx kept for it", %{conn: conn} do
    stub_status(config())

    :ok =
      Foundation.Catalog.add_relup(@name, %{
        from_version: "1.4.1",
        to_version: "1.4.2",
        summary: %{
          applications: [{"myphoenixapp", "1.4.2"}, {"finch", "0.25.0"}],
          modules: 12,
          updated: ["Myphoenixapp.Worker"],
          removed: [],
          applies: ["supervisor.restart_child/2"],
          runtime_config: true,
          restart_emulator: false,
          instructions: 31
        },
        steps:
          Relup.steps([
            {:apply, {:erl_eval, :exprs, [[{:atom, 0, :ok}], []]}},
            {:load_object_code,
             {:myphoenixapp, ~c"1.4.2", [Myphoenixapp.Worker, MyphoenixappWeb]}},
            :point_of_no_return,
            {:suspend, [Myphoenixapp.Worker]},
            {:load, {Myphoenixapp.Worker, :brutal_purge, :soft_purge}},
            {:load, {MyphoenixappWeb, :brutal_purge, :soft_purge}},
            {:code_change, :up, [{Myphoenixapp.Worker, []}]},
            {:resume, [Myphoenixapp.Worker]}
          ]),
        text: "{\"1.4.2\",[{\"1.4.1\",[],[point_of_no_return]}],[]}.\n",
        inserted_at: ~N[2026-10-28 12:14:00]
      })

    on_exit(fn ->
      File.rm_rf(
        Path.join([
          Application.fetch_env!(:foundation, :var_path),
          "storage",
          @name,
          "deployex",
          "relup"
        ])
      )
    end)

    {:ok, view, html} = live(conn, ~p"/applications/#{@name}/versions")

    # Only the hot upgrade that knows where it came from offers its relup
    assert [_one] = Regex.scan(~r/phx-click="relup"/, html)
    refute has_element?(view, "#relup")

    html = view |> element(~s(button[phx-click="relup"])) |> render_click()

    assert html =~ "Relup · 1.4.1 → 1.4.2"
    assert html =~ "Replaces code in 2 applications: myphoenixapp 1.4.2, finch 0.25.0"
    assert html =~ "Loads 12 modules"
    assert html =~ "Suspends the processes of Myphoenixapp.Worker and runs their code_change"
    assert html =~ "Calls supervisor.restart_child/2"
    assert html =~ "Applies the runtime configuration"
    assert html =~ "31 instructions in all"
    refute html =~ "Restarts the VM"

    # The steps the node ran, in order, each with what it means
    steps = view |> element("#relup-steps") |> render()

    assert [_one, _two, _three, _four, _five, _six, _seven] = Regex.scan(~r/<li/, steps)
    assert steps =~ "Added by DeployEx"
    assert steps =~ "point_of_no_return"
    assert steps =~ "From here on a failure cannot be undone"
    assert steps =~ "Pauses the processes that run these modules"
    # The load of each module is one step, with its purge options and what they mean
    assert steps =~ "5–6"
    assert steps =~ "Myphoenixapp.Worker, MyphoenixappWeb"
    assert steps =~ "No process is restarted"
    assert steps =~ "The options only matter for a process that is still inside older code"
    assert steps =~ "Second option (soft_purge): the replaced version is purged only once"
    assert steps =~ "Lets the paused processes run again"
    assert steps |> :binary.match("suspend") < steps |> :binary.match("resume")

    # The file itself is one click away, with a button that copies it
    refute has_element?(view, "#relup-text")
    html = view |> element("#relup-view-original") |> render_click()
    assert html =~ "The relup as DeployEx installed it"
    assert view |> element("#relup-text") |> render() =~ "point_of_no_return"
    assert has_element?(view, "#relup-copy")
    refute has_element?(view, "#relup-steps")

    assert view |> element("#relup-view-steps") |> render_click() =~ "Outcome"

    refute view |> element("#relup-close") |> render_click() =~ "Relup ·"

    # The link of an open relup closes it too
    assert view |> element(~s(button[phx-click="relup"])) |> render_click() =~ "Relup ·"
    refute view |> element(~s(button[phx-click="relup"])) |> render_click() =~ "Relup ·"
  end

  @tag :capture_log
  test "a hot upgrade whose relup was not kept says so", %{conn: conn} do
    stub_status(config())

    {:ok, view, _html} = live(conn, ~p"/applications/#{@name}/versions")

    html = view |> element(~s(button[phx-click="relup"])) |> render_click()

    assert html =~ "Relup · 1.4.1 → 1.4.2"
    assert html =~ "DeployEx has no relup for this hot upgrade"
    refute has_element?(view, "#relup-text")
  end

  @tag :capture_log
  test "pins a version after a confirmation", %{conn: conn} do
    stub_status(config())

    {:ok, view, _html} = live(conn, ~p"/applications/#{@name}/versions")

    html = view |> element("#mode-pin") |> render_click()
    assert html =~ "Version to pin"
    assert html =~ "1.4.2 (current)"
    assert html =~ "Pin 1.4.1…"

    html = view |> element("#mode-form") |> render_change(%{"version" => "1.4.0"})
    assert html =~ "Pin 1.4.0…"

    html = view |> element("#mode-save") |> render_click()

    assert html =~
             "Pin myphoenixapp to 1.4.0? DeployEx deploys 1.4.0 to the instance and stops following current.json."

    html = view |> element("button", "Cancel") |> render_click()
    refute html =~ "stops following current.json."

    view |> element("#mode-save") |> render_click()
    view |> element("#mode-confirm") |> render_click()
    assert_receive {:set_mode, :manual, "1.4.0"}
  end

  @tag :capture_log
  test "a pinned app goes back to Automatic after a confirmation", %{conn: conn} do
    stub_status(config(:manual, %Catalog.Version{version: "1.4.1"}))

    {:ok, view, html} = live(conn, ~p"/applications/#{@name}/versions")
    assert html =~ "Pinned to 1.4.1"
    assert html =~ "DeployEx keeps the instance on 1.4.1"

    view |> element("#mode-automatic") |> render_click()
    html = view |> element("#mode-save") |> render_click()
    assert html =~ "Set myphoenixapp to Automatic?"

    view |> element("#mode-confirm") |> render_click()
    assert_receive {:set_mode, :automatic, ""}
  end

  @tag :capture_log
  test "the history shows one instance's versions from its own path", %{conn: conn} do
    stub_status(config())

    {:ok, view, _html} = live(conn, ~p"/applications/#{@name}/#{@sname}/versions")
    assert has_element?(view, ~s(a[aria-pressed="true"]), "abc123")

    render_patch(view, ~p"/applications/#{@name}/versions")
    assert has_element?(view, ~s(a[aria-pressed="true"]), "All instances")
    refute has_element?(view, ~s(a[aria-pressed="true"]), "abc123")

    # Another node's update changes nothing, this node's updates the page from its statuses
    {:ok, statuses} = Deployer.Status.monitoring()
    send(view.pid, {:monitoring_app_updated, :other@host, []})
    send(view.pid, {:monitoring_app_updated, Node.self(), statuses})
    assert render(view) =~ "1.4.1"
  end

  @tag :capture_log
  test "an update reads the history again only when the versions change", %{conn: conn} do
    test_pid = self()
    stub_status(config())

    stub(Deployer.StatusMock, :history_version_list, fn @name, [] ->
      send(test_pid, :history_read)
      [version("1.4.2", :hot_upgrade, ~N[2026-10-28 12:14:00])]
    end)

    {:ok, view, _html} = live(conn, ~p"/applications/#{@name}/versions")
    assert_received :history_read
    {:ok, [deployex, app]} = Deployer.Status.monitoring()

    # The same versions, every second: no read
    for _tick <- 1..3, do: send(view.pid, {:monitoring_app_updated, Node.self(), [deployex, app]})
    render(view)
    refute_received :history_read

    # A new version: one read
    newer = %{app | config: %{app.config | versions: ["1.4.3" | app.config.versions]}}
    send(view.pid, {:monitoring_app_updated, Node.self(), [deployex, newer]})
    render(view)
    assert_received :history_read
  end

  @tag :capture_log
  test "an app this host does not run has no history, and its catalog is not read", %{conn: conn} do
    Deployer.StatusMock
    |> stub(:monitoring, fn -> {:ok, [FixtureStatus.deployex()]} end)
    |> stub(:subscribe, fn -> :ok end)
    |> expect(:history_version_list, 0, fn _name, [] -> [] end)

    {:ok, _view, html} = live(conn, ~p"/applications/unknown/versions")
    assert html =~ "No version has run on this host yet."
    assert html =~ "current none"
  end
end
