defmodule DeployexWeb.Fleet.IndexTest do
  use DeployexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mock

  setup [:log_in_default_user]

  defp instance(sname, version), do: %{sname: sname, version: version, running?: true}

  defp summary(host, attrs) do
    Map.merge(
      %{
        node: :"deployex@#{host}",
        host: host,
        answers?: true,
        deployex_version: "0.10.0",
        applications: [],
        locks: []
      },
      Map.new(attrs)
    )
  end

  defp lock(state, node, since) do
    %{
      name: "myapp",
      state: state,
      node: node,
      owner: self(),
      sname: "myapp-abc123",
      from_version: "1.0.0",
      to_version: "1.1.0",
      since: since,
      expires_at: since + 60_000
    }
  end

  defp application(version, ghosted \\ []) do
    %{
      name: "myapp",
      language: "elixir",
      ghosted: ghosted,
      instances: [instance("myapp-abc123", version)]
    }
  end

  defp fleet do
    now = System.system_time(:millisecond)

    [
      summary("dx-0", node: Node.self(), applications: [application("1.1.0")]),
      summary("dx-1",
        applications: [application("1.0.0")],
        locks: [lock(:held, :"deployex@dx-1", now - 20_000)]
      ),
      summary("dx-2",
        applications: [application("1.0.0", ["0.9.0"])],
        locks: [lock(:waiting, :"deployex@dx-2", now - 15_000)]
      ),
      summary("dx-3", answers?: false, deployex_version: nil)
    ]
  end

  @tag :capture_log
  test "a DeployEx that is alone says how to connect it to others", %{conn: conn} do
    with_mock Deployer.Fleet, [:passthrough],
      summaries: fn -> [summary("dx-0", node: Node.self())] end do
      {:ok, _view, html} = live(conn, ~p"/fleet")

      assert html =~ "1 DeployEx"
      assert html =~ "This DeployEx"
      assert html =~ "No application"
      assert html =~ "peers_dns_query"
      refute html =~ "fleet-cancel"
    end
  end

  @tag :capture_log
  test "shows every DeployEx with its versions, what it ghosted and its lock", %{conn: conn} do
    with_mock Deployer.Fleet, [:passthrough], summaries: fn -> fleet() end do
      {:ok, view, html} = live(conn, ~p"/fleet")

      assert html =~ "4 DeployEx"
      refute html =~ "peers_dns_query"
      assert html =~ "myapp runs 1.0.0 and 1.1.0"

      assert view |> element("#fleet-node-dx-0") |> render() =~ "This DeployEx"
      assert view |> element("#fleet-node-dx-0") |> render() =~ "Idle"

      deploying = view |> element("#fleet-node-dx-1") |> render()
      assert deploying =~ "Deploying"
      assert deploying =~ "1.0.0 → 1.1.0"
      assert deploying =~ "fleet-cancel-dx-1-myapp"

      waiting = view |> element("#fleet-node-dx-2") |> render()
      assert waiting =~ "Waiting"
      assert waiting =~ "0.9.0"
      refute waiting =~ "fleet-cancel"

      assert view |> element("#fleet-node-dx-3") |> render() =~ "does not answer"
    end
  end

  @tag :capture_log
  test "Cancel asks first, then cancels the deployment on that node", %{conn: conn} do
    test_pid = self()

    with_mocks [
      {Deployer.Fleet, [:passthrough], summaries: fn -> fleet() end},
      {Deployer.Lock, [:passthrough],
       cancel: fn node, name ->
         send(test_pid, {:cancelled, node, name})
         :ok
       end}
    ] do
      {:ok, view, _html} = live(conn, ~p"/fleet")

      html = view |> element("#fleet-cancel-dx-1-myapp") |> render_click()
      assert html =~ "Cancel the deployment of myapp on dx-1?"
      refute_received {:cancelled, _node, _name}

      html = view |> element("button", "Keep it") |> render_click()
      refute html =~ "Cancel the deployment of myapp on dx-1?"

      view |> element("#fleet-cancel-dx-1-myapp") |> render_click()
      html = view |> element("#fleet-cancel-confirm") |> render_click()

      assert_received {:cancelled, :"deployex@dx-1", "myapp"}
      refute html =~ "Cancel the deployment of myapp on dx-1?"
    end
  end

  @tag :capture_log
  test "Cancel does nothing and warns when the deployment already moved on", %{conn: conn} do
    with_mocks [
      {Deployer.Fleet, [:passthrough], summaries: fn -> fleet() end},
      {Deployer.Lock, [:passthrough], cancel: fn _node, _name -> :ok end}
    ] do
      {:ok, view, _html} = live(conn, ~p"/fleet")

      view |> element("#fleet-cancel-dx-1-myapp") |> render_click()

      # The lock dx-1 held is gone by the time the cancel is confirmed
      next_fleet = List.update_at(fleet(), 1, &%{&1 | locks: []})
      :meck.expect(Deployer.Fleet, :summaries, fn -> next_fleet end)
      send(view.pid, :refresh)
      render(view)

      html = view |> element("#fleet-cancel-confirm") |> render_click()

      assert html =~ "Could not cancel the deployment of myapp on dx-1"
      assert_not_called(Deployer.Lock.cancel(:_, :_))
    end
  end

  @tag :capture_log
  test "Cancel warns when the deployment does not cancel", %{conn: conn} do
    with_mocks [
      {Deployer.Fleet, [:passthrough], summaries: fn -> fleet() end},
      {Deployer.Lock, [:passthrough], cancel: fn _node, _name -> {:error, :timeout} end}
    ] do
      {:ok, view, _html} = live(conn, ~p"/fleet")

      view |> element("#fleet-cancel-dx-1-myapp") |> render_click()
      html = view |> element("#fleet-cancel-confirm") |> render_click()

      assert html =~ "Could not cancel the deployment of myapp on dx-1"
    end
  end

  @tag :capture_log
  test "the menu has the page", %{conn: conn} do
    with_mock Deployer.Fleet, [:passthrough],
      summaries: fn -> [summary("dx-0", node: Node.self())] end do
      {:ok, _view, html} = live(conn, ~p"/fleet")
      assert html =~ ~s(href="/fleet")
    end
  end
end
