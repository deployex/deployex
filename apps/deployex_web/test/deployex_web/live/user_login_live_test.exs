defmodule DeployexWeb.UserLoginLiveTest do
  use DeployexWeb.ConnCase

  import Phoenix.LiveViewTest
  import DeployexWeb.AccountsFixtures

  describe "Log in page" do
    @tag :capture_log
    test "renders log in page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log_in")

      assert html =~ "DeployEx"
      assert html =~ "Sign in to the management console"
    end

    test "shows a flash message, such as a denied sign-in", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> init_test_session(%{
          "phoenix_flash" => %{"error" => "Not authorized for this instance."}
        })
        |> live(~p"/users/log_in")

      assert html =~ "Not authorized for this instance."
    end

    @tag :capture_log
    test "has no credentials filled in outside development, whatever is configured at runtime",
         %{conn: conn} do
      # config/dev.exs is the only place that sets them, and they are read at compile time
      Application.put_env(:deployex_web, :dev_login, username: "admin", password: "deployex")
      on_exit(fn -> Application.delete_env(:deployex_web, :dev_login) end)

      {:ok, _lv, html} = live(conn, ~p"/users/log_in")

      refute html =~ "dev-login-note"
      refute html =~ ~s(value="admin")
      refute html =~ ~s(value="deployex")
    end

    @tag :capture_log
    test "names the credential fields so password managers stay on this form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log_in")

      assert html =~ ~s(autocomplete="username")
      assert html =~ ~s(autocomplete="current-password")
    end

    @tag :capture_log
    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/log_in")
        |> follow_redirect(conn, ~p"/applications")

      assert {:ok, _conn} = result
    end
  end

  describe "OAuth button" do
    setup do
      original = Application.get_env(:deployex_web, DeployexWeb.OAuth)

      on_exit(fn ->
        if original do
          Application.put_env(:deployex_web, DeployexWeb.OAuth, original)
        else
          Application.delete_env(:deployex_web, DeployexWeb.OAuth)
        end
      end)

      :ok
    end

    @tag :capture_log
    test "is hidden when OAuth is not configured", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log_in")

      refute html =~ "Sign in with GitHub"
    end

    @tag :capture_log
    test "is hidden when the client_secret is missing", %{conn: conn} do
      Application.put_env(:deployex_web, DeployexWeb.OAuth,
        client_id: "Ov23liExample",
        redirect_uri: "http://localhost:5001/auth/github/callback"
      )

      {:ok, _lv, html} = live(conn, ~p"/users/log_in")

      refute html =~ "Sign in with GitHub"
    end

    @tag :capture_log
    test "is shown when OAuth is configured", %{conn: conn} do
      Application.put_env(:deployex_web, DeployexWeb.OAuth,
        client_id: "Ov23liExample",
        client_secret: "secret",
        redirect_uri: "http://localhost:5001/auth/github/callback"
      )

      {:ok, _lv, html} = live(conn, ~p"/users/log_in")

      assert html =~ "Sign in with GitHub"
    end
  end

  describe "user login" do
    @tag :capture_log
    test "redirects if user login with valid credentials", %{conn: conn} do
      password = "deployex"
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log_in")

      form =
        form(lv, "#login_form",
          user: %{username: user.username, password: password, remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/applications"
    end

    @tag :capture_log
    test "redirects to login page with a flash error if there are no valid credentials", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/log_in")

      form =
        form(lv, "#login_form",
          user: %{username: "invalid", password: "123456", remember_me: true}
        )

      conn = submit_form(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"

      assert redirected_to(conn) == "/users/log_in"
    end
  end
end
