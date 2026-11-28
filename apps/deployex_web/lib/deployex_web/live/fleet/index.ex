defmodule DeployexWeb.FleetLive do
  @moduledoc """
  This DeployEx and the ones it is connected to, side by side: what each host runs, what
  it ghosted, and which one is deploying or waiting to. It reads the others, and acts on
  them in one way only, to cancel the deployment that holds the lock.
  """
  use DeployexWeb, :live_view

  alias Deployer.Fleet
  alias Deployer.Lock
  alias DeployexWeb.ApplicationsLive.View
  alias DeployexWeb.UI.Icons

  @refresh_ms 2_000
  @columns "grid grid-cols-[minmax(140px,1fr)_minmax(90px,0.6fr)_minmax(220px,2fr)_minmax(240px,2fr)] " <>
             "items-start gap-x-4"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, columns: @columns, drift: Fleet.drift(assigns.nodes))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_user={@current_user}
      host_info={@host_info}
      recent_events={@recent_events}
      socket={@socket}
    >
      <div class="mx-auto flex max-w-[1140px] flex-col gap-5 px-8 pt-5 pb-14 max-md:px-4">
        <div class="flex flex-col gap-2.5">
          <div class="flex flex-wrap items-center gap-3">
            <h1 class="text-xl font-bold">Fleet</h1>
            <span :if={@nodes != []} class="dx-chip">
              {if length(@nodes) == 1, do: "1 DeployEx", else: "#{length(@nodes)} DeployEx"}
            </span>
            <span
              :for={{name, versions} <- @drift}
              id={"fleet-drift-#{name}"}
              class="dx-chip dx-s-start"
            >
              {name} runs {Enum.join(versions, " and ")}
            </span>
          </div>
          <p class="dx-muted max-w-[720px] text-[0.875rem]">
            Each DeployEx deploys on its own host. This page shows the ones this DeployEx is connected to,
            and the order they deploy in: one host at a time for each application.
          </p>
        </div>

        <section class="dx-card overflow-hidden" aria-label="DeployEx nodes">
          <div class="overflow-x-auto">
            <div class="min-w-[760px]">
              <div class={[@columns, "min-h-[38px] items-center px-5"]}>
                <div class="dx-lbl">Host</div>
                <div class="dx-lbl">DeployEx</div>
                <div class="dx-lbl">Applications</div>
                <div class="dx-lbl">Deployment</div>
              </div>
              <div
                :for={node <- @nodes}
                id={"fleet-node-#{node.host}"}
                class={[@columns, "border-t border-(--dx-base-300) px-5 py-3"]}
              >
                <div class="min-w-0 flex flex-col gap-1">
                  <b class="dx-mono text-sm truncate" title={node.host}>{node.host}</b>
                  <span :if={node.node == Node.self()} class="dx-muted text-[0.8125rem]">
                    This DeployEx
                  </span>
                </div>
                <div
                  class="dx-mono min-w-0 truncate text-[0.8125rem]"
                  title={node.deployex_version || "--"}
                >
                  {node.deployex_version || "--"}
                </div>
                <div class="min-w-0 flex flex-col gap-1.5">
                  <span :if={not node.answers?} class="dx-muted text-[0.8125rem]">
                    Connected, and it does not answer
                  </span>
                  <span
                    :if={node.answers? and node.applications == []}
                    class="dx-muted text-[0.8125rem]"
                  >
                    No application
                  </span>
                  <div
                    :for={app <- node.applications}
                    class="flex flex-wrap items-center gap-x-2.5 gap-y-1 text-[0.8125rem]"
                  >
                    <b class="wrap-anywhere">{app.name}</b>
                    <span class="dx-mono wrap-anywhere">{versions(app)}</span>
                    <span class="dx-muted">{running(app)}</span>
                    <span :if={app.ghosted != []} class="dx-chip dx-s-ghost wrap-anywhere">
                      <Icons.icon name="ghost" class="dx-gh" />
                      {Enum.join(app.ghosted, ", ")}
                    </span>
                  </div>
                </div>
                <div class="min-w-0 flex flex-col gap-1.5">
                  <span :if={node.locks == []} class="dx-muted text-[0.8125rem]">Idle</span>
                  <div
                    :for={lock <- node.locks}
                    class="flex flex-wrap items-center gap-x-2.5 gap-y-1 text-[0.8125rem]"
                  >
                    <span class={["dx-chip", lock_class(lock.state)]}>{lock_label(lock.state)}</span>
                    <span class="wrap-anywhere">
                      <b>{lock.name}</b>
                      <span class="dx-mono">{lock.from_version} → {lock.to_version}</span>
                    </span>
                    <span class="dx-muted">{View.age(since(lock), @now)}</span>
                    <button
                      :if={lock.state == :held}
                      id={"fleet-cancel-#{node.host}-#{lock.name}"}
                      type="button"
                      class="dx-btn dx-btn-er"
                      phx-click="cancel"
                      phx-value-host={node.host}
                      phx-value-name={lock.name}
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>
          <div :if={@asking} class="dx-ask" role="group" aria-label="Confirm the cancel">
            <span class="flex-[1_1_320px]">
              <b>Cancel the deployment of {elem(@asking, 1)} on {elem(@asking, 0)}?</b>
              That host goes back to the version it had and ghosts the new one. The hosts that wait
              deploy next.
            </span>
            <button
              id="fleet-cancel-confirm"
              type="button"
              class="dx-btn dx-btn-danger"
              phx-click="confirm-cancel"
            >
              Cancel the deployment
            </button>
            <button type="button" class="dx-btn" phx-click="keep">Keep it</button>
          </div>
          <p
            :if={length(@nodes) == 1}
            class="dx-muted border-t border-(--dx-base-300) px-5 py-[18px] text-[0.875rem]"
          >
            This DeployEx is not connected to another one. Where there is one on each of several hosts,
            <code class="dx-mono">peers_dns_query</code>
            in the YAML connects them.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     socket
     |> assign(asking: nil, current_path: "/fleet", page_title: "Fleet")
     |> load()}
  end

  @impl true
  def handle_event("cancel", %{"host" => host, "name" => name}, socket),
    do: {:noreply, assign(socket, :asking, {host, name})}

  def handle_event("keep", _params, socket), do: {:noreply, assign(socket, :asking, nil)}

  # The host comes from the page, so the node and the lock are looked up again in what was
  # last loaded, since the deployment the dialog asked about may have moved on by the time
  # it is confirmed
  def handle_event("confirm-cancel", _params, %{assigns: %{asking: {host, name}}} = socket) do
    socket =
      case Enum.find(socket.assigns.nodes, &(&1.host == host)) do
        %{node: node} = node_summary ->
          if held_lock?(node_summary, name) do
            case Lock.cancel(node, name) do
              :ok -> socket
              {:error, _reason} -> flash_cancel_failed(socket, name, host)
            end
          else
            flash_cancel_failed(socket, name, host)
          end

        nil ->
          flash_cancel_failed(socket, name, host)
      end

    {:noreply, socket |> assign(:asking, nil) |> load()}
  end

  def handle_event("confirm-cancel", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    nodes = if connected?(socket), do: Fleet.summaries(), else: []
    assign(socket, nodes: nodes, now: DateTime.utc_now())
  end

  defp versions(%{instances: instances}) do
    case instances |> Enum.map(& &1.version) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> "--"
      versions -> Enum.join(versions, ", ")
    end
  end

  defp running(%{instances: instances}),
    do: "#{Enum.count(instances, & &1.running?)}/#{length(instances)} running"

  defp since(%{since: since}), do: DateTime.from_unix!(since, :millisecond)

  defp held_lock?(%{locks: locks}, name),
    do: Enum.any?(locks, &(&1.name == name and &1.state == :held))

  defp flash_cancel_failed(socket, name, host),
    do: put_flash(socket, :error, "Could not cancel the deployment of #{name} on #{host}")

  defp lock_label(:held), do: "Deploying"
  defp lock_label(:waiting), do: "Waiting"
  defp lock_label(:forced), do: "Deploying, the lock was not given back"

  defp lock_class(:held), do: "dx-s-info"
  defp lock_class(:waiting), do: "dx-s-start"
  defp lock_class(:forced), do: "dx-s-ghost"
end
