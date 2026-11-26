defmodule DeployexWeb.AuthorizationTest do
  # async: false, the tests change the shared OAuth application environment
  use DeployexWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias DeployexWeb.Authorization
  alias DeployexWeb.Fixture.Status, as: FixtureStatus
  alias Foundation.Accounts

  doctest DeployexWeb.Authorization

  setup [:set_mox_global, :verify_on_exit!]

  @email "viewer@co.com"

  # A single sign-on user whose email is on the read-only list
  defp log_in_read_only(%{conn: conn}) do
    original = Application.get_env(:deployex_web, DeployexWeb.OAuth)

    on_exit(fn ->
      if original,
        do: Application.put_env(:deployex_web, DeployexWeb.OAuth, original),
        else: Application.delete_env(:deployex_web, DeployexWeb.OAuth)
    end)

    Application.put_env(:deployex_web, DeployexWeb.OAuth,
      client_id: "Ov23liExample",
      client_secret: "secret",
      redirect_uri: "http://localhost:5001/auth/github/callback",
      allowlist: %{emails: [], domains: [], read_only_emails: [@email]}
    )

    token = Accounts.generate_user_session_token(%{username: @email})

    conn =
      conn
      |> Map.replace!(:secret_key_base, DeployexWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> put_session(:oauth_token, token)

    %{conn: conn}
  end

  defp stub_applications do
    Deployer.StatusMock
    |> stub(:monitoring, fn ->
      {:ok, [FixtureStatus.deployex(), FixtureStatus.application(%{name: "myphoenixapp"})]}
    end)
    |> stub(:subscribe, fn -> :ok end)
    |> stub(:history_version_list, fn _name, _options -> FixtureStatus.versions() end)

    stub(Foundation.RpcMock, :call, fn _node, _module, _function, _args, _timeout ->
      {:badrpc, :nodedown}
    end)
  end

  describe "a read-only user" do
    setup [:log_in_read_only]

    @tag :capture_log
    test "is not offered the pages for admins, and is told its access", %{conn: conn} do
      stub_applications()
      {:ok, _view, html} = live(conn, ~p"/applications")

      assert html =~ "Read-only access"
      assert html =~ ~s(href="/logs/live")
      refute html =~ ~s(href="/terminal")
      refute html =~ ~s(href="/hotupgrade")
      refute html =~ ~s(href="/embedded-observer")
    end

    @tag :capture_log
    test "cannot open the pages for admins", %{conn: conn} do
      for path <- [~p"/terminal", ~p"/hotupgrade", ~p"/hotupgrade/apply", ~p"/embedded-observer"] do
        assert {:error, {:redirect, %{to: "/applications"}}} = live(conn, path)
      end

      assert conn |> get("/observer") |> redirected_to() == ~p"/applications"
    end

    @tag :capture_log
    test "looks at the applications, and cannot restart one", %{conn: conn} do
      stub_applications()
      expect(Deployer.MonitorMock, :restart, 0, fn _sname, _options -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/applications")

      # An event that only changes what is shown goes through
      refute view |> element("#app-myphoenixapp-toggle") |> render_click() =~
               Authorization.refused()

      for {event, params} <- [
            {"restart-instance", %{"sname" => "myphoenixapp-abc123"}},
            {"restart-app", %{"name" => "myphoenixapp"}},
            {"restart-deployex", %{}},
            {"clear-ghosted", %{"name" => "myphoenixapp"}},
            {"config-changes-apply", %{}},
            {"ask", %{"target" => "deployex"}},
            {"an-event-added-later", %{}}
          ] do
        assert render_hook(view, event, params) =~ Authorization.refused()
      end
    end

    @tag :capture_log
    test "cannot pin a version or clear a ghosted one", %{conn: conn} do
      stub_applications()

      Deployer.StatusMock
      |> stub(:subscribe_ghosted_versions, fn _name -> :ok end)
      |> stub(:ghosted_version_list, fn _name -> [] end)
      |> expect(:set_mode, 0, fn _name, _mode, _version -> {:ok, %{}} end)
      |> expect(:remove_ghosted_version, 0, fn _name, _version -> {:ok, []} end)

      {:ok, view, _html} = live(conn, ~p"/applications/myphoenixapp/ghosted")
      assert render_hook(view, "confirm-clear", %{}) =~ Authorization.refused()
      assert render_hook(view, "clear-all", %{}) =~ Authorization.refused()
    end

    @tag :capture_log
    test "opens a log tab in the dock, and no shell", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/documentation")
      dock = find_live_child(view, "dock-live")

      html = render_hook(dock, "open", %{"kind" => "shell", "target" => "deployex"})
      assert html =~ Authorization.refused()
      refute has_element?(dock, "#dock-tab-shell-deployex")

      html = render_hook(dock, "shell-keys", %{"target" => "deployex", "keys" => "ls\n"})
      assert html =~ Authorization.refused()
    end
  end

  describe "the built-in admin" do
    setup [:log_in_default_user]

    @tag :capture_log
    test "is offered every page", %{conn: conn} do
      stub_applications()
      {:ok, _view, html} = live(conn, ~p"/applications")

      refute html =~ "Read-only access"
      assert html =~ ~s(href="/terminal")
      assert html =~ ~s(href="/hotupgrade")
      assert html =~ ~s(href="/embedded-observer")
    end
  end

  test "every event of a page that a read-only user can send is one the page handles" do
    for {view, events} <- %{
          DeployexWeb.ApplicationsLive => "live/applications/index.ex",
          DeployexWeb.VersionsLive => "live/applications/versions_live.ex",
          DeployexWeb.GhostedLive => "live/applications/ghosted_live.ex",
          DeployexWeb.LogsLive => "live/logs/index.ex",
          DeployexWeb.DockLive => "live/dock.ex"
        } do
      source = File.read!(Path.join([File.cwd!(), "lib/deployex_web", events]))

      handled =
        ~r/def handle_event\(\s*"([^"]+)"/
        |> Regex.scan(source, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      # Something a read-only user can send, and something it cannot
      allowed =
        Enum.filter(
          handled,
          &Authorization.event_allowed?(:read_only, view, &1, %{"kind" => "logs"})
        )

      assert allowed != [], "#{inspect(view)} lets a read-only user send nothing"
      assert handled -- allowed != [] or view == DeployexWeb.LogsLive
    end
  end
end
