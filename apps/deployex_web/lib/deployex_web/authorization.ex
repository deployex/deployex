defmodule DeployexWeb.Authorization do
  @moduledoc """
  What a signed-in user can do in the dashboard: everything as an admin, or look only with
  read-only access.

  The role comes with the sign-in. The built-in `admin` user is an admin. A single sign-on
  user has the role its provider gives it, see `DeployexWeb.OAuth.Allowlist`.

  ## Read-only access

  It is denied by default, in three places, and none of them trusts what the page shows:

    * **Pages** - the Terminal, Observer Web and Hot Upgrade pages are for admins. A shell
      on the host, the processes of a running node and the code it runs are not something
      to look at only. `:ensure_admin` and `require_admin/2` guard them.
    * **Events** - every event of a page is refused, except the ones listed in
      `@read_only_events` for that page: the ones that change what is shown and nothing
      else. An event that is added to a page is refused until it is listed here.
    * **The dock** - log tabs only, no shell.

  A read-only user who clicks a control that changes something is told so, and nothing
  happens.
  """

  use DeployexWeb, :verified_routes

  import Phoenix.Component, only: [assign_new: 3]

  alias Phoenix.LiveView

  @type role :: :admin | :read_only

  # The events a read-only user can send to each page. They filter, expand, pick what to
  # look at, or cancel a question. Everything else is refused.
  @read_only_events %{
    DeployexWeb.ApplicationsLive =>
      ~w(show-instance toggle-app toggle-attention toggle-distribution toggle-limits cancel-ask confirm-close-modal),
    DeployexWeb.VersionsLive => ~w(segment relup relup_view close_relup cancel),
    DeployexWeb.GhostedLive => ~w(cancel-clear),
    DeployexWeb.LogsLive =>
      ~w(clear every-app filter mode pause range toggle-app toggle-source toggle-stream),
    DeployexWeb.FleetLive => ~w(keep),
    DeployexWeb.DockLive =>
      ~w(open split-open split-pick toggle-help select unsplit close-tab close cancel-close confirm-close filter-logs toggle-stream)
  }

  @refused "You have read-only access."

  ### ==========================================================================
  ### Public APIs
  ### ==========================================================================

  @doc """
  The role of a user. One without a role, which no sign-in makes, has read-only access.

  ## Examples

      iex> DeployexWeb.Authorization.role(%Foundation.Accounts.User{username: "admin"})
      :admin
      iex> DeployexWeb.Authorization.role(%{email: "ana@example.com", role: :read_only})
      :read_only
      iex> DeployexWeb.Authorization.role(%{email: "ana@example.com"})
      :read_only
      iex> DeployexWeb.Authorization.role(nil)
      :read_only
  """
  @spec role(term()) :: role()
  def role(%{role: :admin}), do: :admin
  def role(_user), do: :read_only

  @doc """
  Whether the user is an admin.
  """
  @spec admin?(term()) :: boolean()
  def admin?(user), do: role(user) == :admin

  @doc """
  Whether a user with `role` can send `event` to the LiveView `view`.

  The dock opens a tab with `open` and `split-open`, which a read-only user can send for
  a log tab only.

  ## Examples

      iex> alias DeployexWeb.Authorization
      iex> Authorization.event_allowed?(:admin, DeployexWeb.ApplicationsLive, "restart-app", %{})
      true
      iex> Authorization.event_allowed?(:read_only, DeployexWeb.ApplicationsLive, "restart-app", %{})
      false
      iex> Authorization.event_allowed?(:read_only, DeployexWeb.ApplicationsLive, "toggle-app", %{})
      true
      iex> Authorization.event_allowed?(:read_only, DeployexWeb.DockLive, "open", %{"kind" => "logs"})
      true
      iex> Authorization.event_allowed?(:read_only, DeployexWeb.DockLive, "open", %{"kind" => "shell"})
      false
      iex> Authorization.event_allowed?(:read_only, DeployexWeb.TerminalLive, "new", %{})
      false
  """
  @spec event_allowed?(role(), module(), String.t(), map()) :: boolean()
  def event_allowed?(:admin, _view, _event, _params), do: true

  def event_allowed?(_role, DeployexWeb.DockLive = view, event, params)
      when event in ["open", "split-open"] do
    params["kind"] == "logs" and event in Map.fetch!(@read_only_events, view)
  end

  def event_allowed?(_role, view, event, _params),
    do: event in Map.get(@read_only_events, view, [])

  @doc """
  The text a read-only user gets for what it cannot do.
  """
  @spec refused() :: String.t()
  def refused, do: @refused

  @doc """
  Refuses the events a read-only user cannot send to the LiveView of `socket`, for the
  rest of its life. `role` is the one the LiveView was mounted with.

  A LiveView that the router mounts gets it from `on_mount(:guard_events, ...)`. One that
  is rendered inside another, the dock, calls it in its own `mount/3`.
  """
  @spec guard_events(LiveView.Socket.t(), role()) :: LiveView.Socket.t()
  def guard_events(socket, :admin), do: socket

  def guard_events(socket, role) do
    LiveView.attach_hook(socket, :authorization, :handle_event, fn event, params, socket ->
      if event_allowed?(role, socket.view, event, params) do
        {:cont, socket}
      else
        {:halt, LiveView.put_flash(socket, :error, @refused)}
      end
    end)
  end

  ### ==========================================================================
  ### LiveView and Plug callbacks
  ### ==========================================================================

  @doc """
  `:guard_events` refuses the events a read-only user cannot send. `:ensure_admin` sends a
  read-only user back to the applications. Both go after the one that signs the user in.
  """
  def on_mount(:guard_events, _params, _session, socket) do
    socket = assign_new(socket, :role, fn -> role(socket.assigns[:current_user]) end)
    {:cont, guard_events(socket, socket.assigns.role)}
  end

  def on_mount(:ensure_admin, _params, _session, socket) do
    if admin?(socket.assigns[:current_user]) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> LiveView.put_flash(:error, @refused)
       |> LiveView.redirect(to: ~p"/applications")}
    end
  end

  @doc """
  A plug for the routes that are for admins, after the one that requires a signed-in user.
  """
  @spec require_admin(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_admin(conn, _opts) do
    if admin?(conn.assigns[:current_user]) do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, @refused)
      |> Phoenix.Controller.redirect(to: ~p"/applications")
      |> Plug.Conn.halt()
    end
  end
end
