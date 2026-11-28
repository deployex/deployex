defmodule DeployexWeb.ObanLive do
  @moduledoc """
  TRIAL ONLY - validates embedding Oban Web the same way "/embedded-observer" embeds
  Observer Web: pick which monitored application to connect to, then load its Oban Web
  dashboard in an iframe. Each app in `@targets` is backed by its own facade Ecto Repo and a
  dashboard-only Oban instance pointed straight at that app's own database - no RPC to the
  app's node. See DeployexWeb.Trial.MonitoredObanRepo for the full explanation.

  In a real version of this feature, `@targets` would come from each monitored app's own
  config (e.g. a `database_url` declared alongside it in deployex.yaml) instead of being
  hardcoded here.
  """
  use DeployexWeb, :live_view

  @targets [
    %{
      key: "myumbrella",
      label: "myumbrella (app_1)",
      detail: "myumbrella_dev on localhost:5432 - live PingWorker traffic",
      path: "/oban-dash/myumbrella"
    },
    %{
      key: "myphoenixapp",
      label: "myphoenixapp",
      detail: "myphoenixapp_prod on localhost:5432",
      path: "/oban-dash/myphoenixapp"
    }
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_user={@current_user}
      host_info={@host_info}
      recent_events={@recent_events}
      socket={@socket}
    >
      <div class="mx-auto flex max-w-[1240px] flex-col gap-4 px-7 pt-6 pb-12 max-md:px-4">
        <header>
          <h1 class="text-[1.625rem] font-bold tracking-[-0.02em]">Oban Web</h1>
          <p class="dx-muted mt-1 text-[0.8125rem]">
            {if @selected,
              do: "Connected to #{@selected.label}",
              else: "Pick which application's Oban instance to connect to."}
          </p>
        </header>

        <section :if={is_nil(@selected)} class="dx-card flex flex-col gap-3 p-5">
          <p class="dx-muted text-[0.8125rem]">
            Each app below has its own Oban tables in its own database. Connecting talks
            directly to that database - DeployEx never reaches into the app's node to do this.
          </p>
          <div class="flex flex-col gap-2">
            <button
              :for={target <- @targets}
              type="button"
              class="dx-btn flex items-center justify-between gap-3 text-left"
              phx-click="select"
              phx-value-app={target.key}
            >
              <span class="flex flex-col">
                <span class="font-semibold">{target.label}</span>
                <span class="dx-muted text-[0.8125rem]">{target.detail}</span>
              </span>
              <span class="dx-muted text-[0.8125rem]">Connect →</span>
            </button>
          </div>
        </section>

        <section :if={@selected} class="dx-card overflow-hidden">
          <div class="flex items-center justify-between border-b border-(--dx-border) px-4 py-2">
            <span class="dx-mono text-[0.8125rem]">{@selected.detail}</span>
            <button type="button" class="dx-btn" phx-click="disconnect">
              Change application
            </button>
          </div>
          <iframe
            src={@selected.path}
            class="block h-[calc(100dvh-var(--dx-topbar-height)-6.5rem)] w-full border-0"
            title={"Oban Web - #{@selected.label}"}
          ></iframe>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, "/oban")
     |> assign(:page_title, "Oban Web")
     |> assign(:targets, @targets)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    selected = Enum.find(@targets, &(&1.key == params["app"]))
    {:noreply, assign(socket, :selected, selected)}
  end

  @impl true
  def handle_event("select", %{"app" => app}, socket) do
    {:noreply, push_patch(socket, to: ~p"/oban?#{%{app: app}}")}
  end

  def handle_event("disconnect", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/oban")}
  end
end
