defmodule DeployexWeb.OAuth.CloudflareAccessTest do
  # async: false, the tests change the shared OAuth application environment
  use DeployexWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias DeployexWeb.Authorization
  alias DeployexWeb.OAuth.CloudflareAccess
  alias DeployexWeb.UserAuth

  @team "myteam.cloudflareaccess.com"
  @audience "f1e2d3c4b5a6"
  @header "cf-access-jwt-assertion"

  # Cloudflare for the tests: the keys of the team and the identity of a user. The test
  # process is told every request.
  defmodule Cloudflare do
    @behaviour DeployexWeb.OAuth.CloudflareAccess.Http

    def set(values), do: :persistent_term.put(__MODULE__, Map.new(values))
    defp get(key), do: Map.fetch!(:persistent_term.get(__MODULE__), key)

    @impl true
    def get_json("https://myteam.cloudflareaccess.com/cdn-cgi/access/certs", []) do
      send(get(:test), :keys_read)
      {:ok, %{"keys" => get(:keys)}}
    end

    def get_json("https://myteam.cloudflareaccess.com/cdn-cgi/access/get-identity", headers) do
      send(get(:test), {:identity_read, headers})
      get(:identity)
    end
  end

  setup %{conn: conn} do
    original = Application.get_env(:deployex_web, DeployexWeb.OAuth)
    Application.put_env(:deployex_web, :cloudflare_access_http, Cloudflare)

    on_exit(fn ->
      Application.delete_env(:deployex_web, :cloudflare_access_http)
      :persistent_term.erase({CloudflareAccess, :keys})

      if original,
        do: Application.put_env(:deployex_web, DeployexWeb.OAuth, original),
        else: Application.delete_env(:deployex_web, DeployexWeb.OAuth)
    end)

    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_kind, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    :persistent_term.erase({CloudflareAccess, :keys})
    Cloudflare.set(test: self(), keys: [public], identity: {:ok, %{"groups" => []}})
    put_config(%{emails: ["admin@co.com"], domains: []})

    conn =
      conn
      |> Map.replace!(:secret_key_base, DeployexWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{conn: conn, key: key}
  end

  defp put_config(allowlist, extra \\ []) do
    Application.put_env(
      :deployex_web,
      DeployexWeb.OAuth,
      Keyword.merge(
        [
          provider: CloudflareAccess,
          team_domain: @team,
          audience: @audience,
          allowlist: allowlist
        ],
        extra
      )
    )
  end

  defp token(key, claims \\ %{}) do
    claims =
      Map.merge(
        %{
          "iss" => "https://#{@team}",
          "aud" => [@audience],
          "email" => "admin@co.com",
          "exp" => System.system_time(:second) + 3_600
        },
        claims
      )

    {_meta, token} = key |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()
    token
  end

  defp user(conn, token) do
    conn = conn |> put_req_header(@header, token) |> UserAuth.fetch_current_user([])
    {conn, conn.assigns.current_user}
  end

  describe "the token" do
    test "of an email on the admin list signs in an admin", %{conn: conn, key: key} do
      assert {conn, %{email: "admin@co.com", role: :admin}} = user(conn, token(key))
      assert_received :keys_read

      # No groups in the auth section, so nothing is asked of the identity provider
      refute_received {:identity_read, _headers}

      assert %{"email" => "admin@co.com", "role" => "admin"} =
               get_session(conn, CloudflareAccess.session_key())
    end

    test "of an email on the read-only list signs in with read-only access", context do
      put_config(%{emails: [], domains: [], read_only_domains: ["co.com"]})

      assert {_conn, %{email: "admin@co.com", role: :read_only}} =
               user(context.conn, token(context.key))
    end

    test "of an email with no role signs nobody in", %{conn: conn, key: key} do
      log =
        capture_log(fn ->
          assert {conn, nil} = user(conn, token(key, %{"email" => "other@co.com"}))
          assert get_session(conn, CloudflareAccess.session_key()) == nil
        end)

      assert log =~ "other@co.com has no role"
    end

    test "is refused when it is for another application of the team", context do
      assert {_conn, nil} = user(context.conn, token(context.key, %{"aud" => ["another-app"]}))

      assert {:error, :invalid_audience} =
               CloudflareAccess.verify(token(context.key, %{"aud" => "x"}))
    end

    test "is refused when it is from another team", %{conn: conn, key: key} do
      other = token(key, %{"iss" => "https://other.cloudflareaccess.com"})

      assert {_conn, nil} = user(conn, other)
      assert {:error, :invalid_issuer} = CloudflareAccess.verify(other)
    end

    test "is refused once it has expired", %{conn: conn, key: key} do
      expired = token(key, %{"exp" => System.system_time(:second) - 1})

      assert {_conn, nil} = user(conn, expired)
      assert {:error, :expired} = CloudflareAccess.verify(expired)
    end

    test "is refused when the team did not sign it", %{conn: conn} do
      forged = token(JOSE.JWK.generate_key({:rsa, 2048}))

      assert {_conn, nil} = user(conn, forged)
      assert {:error, :invalid_signature} = CloudflareAccess.verify(forged)
      assert {:error, :invalid_signature} = CloudflareAccess.verify("not a token")
    end

    test "is not looked at when the auth section is for another provider", context do
      Application.put_env(:deployex_web, DeployexWeb.OAuth,
        client_id: "Ov23liExample",
        allowlist: %{emails: ["admin@co.com"], domains: []}
      )

      assert {_conn, nil} = user(context.conn, token(context.key))
      refute_received :keys_read
    end

    test "is not needed for the built-in password login", %{conn: conn} do
      assert %{assigns: %{current_user: nil}} = UserAuth.fetch_current_user(conn, [])
    end
  end

  describe "the groups" do
    setup do
      put_config(%{
        emails: [],
        domains: [],
        admin_groups: ["deployex-admins"],
        read_only_groups: ["engineering"]
      })
    end

    test "of the user give the role, admin first", %{conn: conn, key: key} do
      token = token(key)

      Cloudflare.set(
        test: self(),
        keys: keys(key),
        identity: {:ok, %{"groups" => ["engineering"]}}
      )

      assert {_conn, %{role: :read_only}} = user(conn, token)
      assert_received {:identity_read, [{"cookie", "CF_Authorization=" <> ^token}]}

      Cloudflare.set(
        test: self(),
        keys: keys(key),
        identity: {:ok, %{"groups" => ["engineering", %{"name" => "deployex-admins"}]}}
      )

      assert {_conn, %{role: :admin}} = user(conn, token)
    end

    test "that are not in the auth section give none", %{conn: conn, key: key} do
      Cloudflare.set(test: self(), keys: keys(key), identity: {:ok, %{"groups" => ["sales"]}})

      capture_log(fn -> assert {_conn, nil} = user(conn, token(key)) end)
    end

    test "that cannot be read give none", %{conn: conn, key: key} do
      Cloudflare.set(test: self(), keys: keys(key), identity: {:error, {:status, 403}})

      log = capture_log(fn -> assert {_conn, nil} = user(conn, token(key)) end)
      assert log =~ "could not be read"
    end

    test "are read once for a token, and again when the auth section changes", context do
      %{conn: conn, key: key} = context
      token = token(key)

      Cloudflare.set(
        test: self(),
        keys: keys(key),
        identity: {:ok, %{"groups" => ["engineering"]}}
      )

      assert {conn, %{role: :read_only}} = user(conn, token)
      assert_received {:identity_read, _headers}

      # The session has the role, for the same token
      assert {conn, %{role: :read_only}} = conn |> recycle_session() |> user(token)
      refute_received {:identity_read, _headers}

      put_config(%{emails: [], domains: [], admin_groups: ["engineering"]})

      assert {_conn, %{role: :admin}} = conn |> recycle_session() |> user(token)
      assert_received {:identity_read, _headers}
    end

    defp keys(key) do
      {_kind, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
      [public]
    end

    # The session of a response, as the browser sends it back with the next request
    defp recycle_session(conn) do
      session = get_session(conn)

      build_conn()
      |> Map.replace!(:secret_key_base, DeployexWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(session)
    end
  end

  describe "the keys of the team" do
    test "are kept, and read again for a token they do not verify", %{conn: conn, key: key} do
      assert {_conn, %{role: :admin}} = user(conn, token(key))
      assert_received :keys_read

      assert {_conn, %{role: :admin}} = user(conn, token(key))
      refute_received :keys_read
    end

    test "that cannot be read sign nobody in", %{conn: conn, key: key} do
      Cloudflare.set(test: self(), keys: :none, identity: {:ok, %{}})

      log = capture_log(fn -> assert {_conn, nil} = user(conn, token(key)) end)
      assert log =~ "keys of Cloudflare Access could not be read"
    end

    test "a failed read is not retried on every request", %{conn: conn, key: key} do
      Cloudflare.set(test: self(), keys: :none, identity: {:ok, %{}})

      capture_log(fn -> assert {_conn, nil} = user(conn, token(key)) end)
      assert_received :keys_read
      refute_received :keys_read

      capture_log(fn -> assert {_conn, nil} = user(conn, token(key)) end)
      refute_received :keys_read
    end

    test "a key Cloudflare sends in a shape that cannot be parsed signs nobody in", %{
      conn: conn,
      key: key
    } do
      Cloudflare.set(test: self(), keys: [%{"kty" => "bogus"}], identity: {:ok, %{}})

      log = capture_log(fn -> assert {_conn, nil} = user(conn, token(key)) end)
      assert log =~ "keys of Cloudflare Access could not be read"
    end
  end

  describe "the dashboard" do
    setup do
      Deployer.StatusMock
      |> Mox.stub(:monitoring, fn -> {:ok, []} end)
      |> Mox.stub(:subscribe, fn -> :ok end)

      Mox.set_mox_global()
      :ok
    end

    @tag :capture_log
    test "opens for a token, with no login", %{conn: conn, key: key} do
      conn = put_req_header(conn, @header, token(key))

      assert {:ok, _view, html} = live(conn, ~p"/applications")
      assert html =~ "admin@co.com"
      refute html =~ "Read-only access"
    end

    @tag :capture_log
    test "opens with read-only access for a read-only user", %{conn: conn, key: key} do
      put_config(%{emails: [], domains: [], read_only_emails: ["admin@co.com"]})
      conn = put_req_header(conn, @header, token(key))

      assert {:ok, view, html} = live(conn, ~p"/applications")
      assert html =~ "Read-only access"
      assert {:error, {:redirect, %{to: "/applications"}}} = live(conn, ~p"/terminal")

      dock = find_live_child(view, "dock-live")

      assert render_hook(dock, "open", %{"kind" => "shell", "target" => "deployex"}) =~
               Authorization.refused()
    end

    @tag :capture_log
    test "asks for the password without a token", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/applications")
    end

    @tag :capture_log
    test "redirects to the login page when the auth config changes", %{conn: conn, key: key} do
      {:ok, liveview, _html} =
        conn |> put_req_header(@header, token(key)) |> live(~p"/applications")

      put_config(%{emails: [], domains: [], read_only_emails: ["admin@co.com"]})
      send(liveview.pid, {:watcher_auth_apply, Node.self()})

      flash = assert_redirect(liveview, ~p"/users/log_in")
      assert flash["error"] == "Not authorized for this instance."
    end

    test "does not take a session whose token has expired", %{key: key} do
      session = %{
        CloudflareAccess.session_key() => %{
          "email" => "admin@co.com",
          "role" => "admin",
          "exp" => System.system_time(:second) - 1,
          "config" => "0",
          "stamp" => token(key)
        }
      }

      assert CloudflareAccess.user_from_session(session) == nil
      assert CloudflareAccess.user_from_session(%{}) == nil
    end
  end
end
