defmodule DeployexWeb.VersionsLive do
  @moduledoc """
  Versions and mode of one application: whether DeployEx follows `current.json` or keeps a pinned
  version, and the version history of its instances.
  """
  use DeployexWeb, :live_view

  alias Deployer.HotUpgrade.Pipelines
  alias Deployer.HotUpgrade.Relup
  alias Deployer.HotUpgrade.VersionUpdate
  alias Deployer.Status
  alias DeployexWeb.ApplicationsLive.Board
  alias DeployexWeb.ApplicationsLive.View
  alias DeployexWeb.HostTime
  alias DeployexWeb.UI.Icons
  alias DeployexWeb.UI.Tags
  alias Foundation.Catalog

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
      <div class="mx-auto flex max-w-[1140px] flex-col gap-5 px-8 pt-5 pb-14 max-md:px-4">
        <Board.app_head
          name={@name}
          language={@language}
          logo={@logo}
          subtitle={"Versions and mode · #{instances(@count)} · current #{@current || "none"}"}
        />

        <section class="dx-card" aria-labelledby="mode-h">
          <div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-3.5 px-[18px] py-4">
            <div class="flex min-w-0 flex-[1_1_360px] flex-col gap-2">
              <div class="flex items-center gap-2.5">
                <h2 id="mode-h" class="text-base font-bold">Mode</h2>
                <span :if={@pinned} class="dx-chip dx-s-info"><span class="dx-dot"></span>Pinned to {@pinned}</span>
                <span :if={is_nil(@pinned)} class="dx-chip dx-s-ok"><span class="dx-dot"></span>Automatic</span>
              </div>
              <p class="dx-muted text-[0.875rem]">{mode_text(@pinned, @count)}</p>
              <p :if={@timing} class="dx-muted text-[0.875rem]">{@timing}</p>
            </div>
            <form id="mode-form" phx-change="pick" class="flex flex-wrap items-end gap-2.5">
              <div class="dx-seg-group" role="group" aria-label="Mode">
                <button
                  id="mode-automatic"
                  type="button"
                  class="dx-seg px-3.5"
                  aria-pressed={to_string(@segment == :automatic)}
                  phx-click="segment"
                  phx-value-segment="automatic"
                >
                  Automatic
                </button>
                <button
                  id="mode-pin"
                  type="button"
                  class="dx-seg px-3.5"
                  aria-pressed={to_string(@segment == :pin)}
                  phx-click="segment"
                  phx-value-segment="pin"
                >
                  Pin a version
                </button>
              </div>
              <div :if={@segment == :pin} class="dx-field">
                <label for="pin-version">Version to pin</label>
                <select id="pin-version" name="version">
                  <option :for={version <- @versions} value={version} selected={version == @pick}>
                    {if version == @current, do: "#{version} (current)", else: version}
                  </option>
                </select>
              </div>
              <button
                :if={
                  changing?(@segment, @pick, @pinned) and not @asking and
                    (@segment == :automatic or @pick != nil)
                }
                id="mode-save"
                type="button"
                class="dx-btn dx-btn-primary min-h-10 text-[0.8125rem]"
                phx-click="ask"
              >
                {if @segment == :pin, do: "Pin #{@pick}…", else: "Set Automatic…"}
              </button>
            </form>
          </div>
          <div
            :if={@asking}
            class="dx-ask dx-ask-warn"
            role="group"
            aria-label="Confirm the mode change"
          >
            <span class="flex-[1_1_360px]">{ask_text(
              @segment,
              @name,
              @pick,
              @current,
              @count
            )}</span>
            <button
              id="mode-confirm"
              type="button"
              class="dx-btn dx-btn-primary min-h-10 text-[0.8125rem]"
              phx-click="confirm"
            >
              {if @segment == :pin, do: "Pin #{@pick}", else: "Set Automatic"}
            </button>
            <button type="button" class="dx-btn min-h-10 text-[0.8125rem]" phx-click="cancel">Cancel</button>
          </div>
        </section>

        <section class="dx-card overflow-hidden" aria-labelledby="hist-h">
          <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2.5 px-5 py-3.5">
            <h2 id="hist-h" class="text-base font-bold">History</h2>
            <div role="group" aria-label="Show the versions of" class="flex flex-wrap gap-1.5">
              <.link
                :for={
                  {label, sname} <- [{"All instances", nil} | Enum.map(@snames, &{suffix(&1), &1})]
                }
                class="dx-tog min-h-9 no-underline"
                aria-pressed={to_string(@filter == sname)}
                patch={
                  if sname,
                    do: ~p"/applications/#{@name}/#{sname}/versions",
                    else: ~p"/applications/#{@name}/versions"
                }
              >
                <Icons.icon
                  :if={@filter == sname}
                  name="check"
                  stroke="2.4"
                  class="dx-ico dx-tog-check size-3.5"
                />
                {label}
              </.link>
            </div>
          </div>
          <div class="overflow-x-auto">
            <div class="min-w-[900px]">
              <div class="dx-vrow min-h-[38px]">
                <div class="dx-lbl">Version</div>
                <div class="dx-lbl">Instance</div>
                <div class="dx-lbl">Deploy</div>
                <div class="dx-lbl" title="What the release asked for in current.json">
                  config_change
                </div>
                <div class="dx-lbl">Deployed, host time {HostTime.zone()}</div>
              </div>
              <%= for row <- rows(@history, @filter, @currents, @now) do %>
                <div class="dx-vrow">
                  <div class="flex items-center gap-2">
                    <b class="dx-mono text-sm">{row.version}</b>
                    <span :if={row.current} class="dx-chip dx-s-ok px-2 py-px text-xs">current</span>
                  </div>
                  <div class="dx-mono text-[0.8125rem]">{row.sname}</div>
                  <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                    <Tags.deploy_tag
                      type={if row.deployment == :hot_upgrade, do: :hot, else: :full}
                      label={if row.deployment == :hot_upgrade, do: "Hot upgrade", else: "Full"}
                    />
                    <button
                      :if={row.from}
                      type="button"
                      class="dx-disclose"
                      title={"What the hot upgrade from #{row.from} did"}
                      aria-expanded={to_string(open?(@relup, row))}
                      aria-controls="relup"
                      phx-click="relup"
                      phx-value-sname={row.sname}
                      phx-value-from={row.from}
                      phx-value-to={row.version}
                    >
                      <Icons.icon name="chevron-right" class="size-3" /> relup
                    </button>
                  </div>
                  <div class="dx-mono text-[0.8125rem]">{row.config_change}</div>
                  <div class="flex items-baseline gap-2.5">
                    <span class="dx-mono text-[0.8125rem]">{row.at}</span>
                    <span class="dx-muted text-[0.8125rem]">{row.age}</span>
                  </div>
                </div>
                <.relup_panel :if={open?(@relup, row)} relup={@relup} />
              <% end %>
              <p
                :if={@history == [] and connected?(@socket)}
                class="dx-muted border-t border-(--dx-base-300) px-5 py-4 text-[0.875rem]"
              >
                No version has run on this host yet.
              </p>
            </div>
          </div>
          <p class="dx-muted border-t border-(--dx-base-300) px-5 pt-3 pb-3.5 text-[0.8125rem]">
            This host keeps the releases of the last {retention()} versions.
            <.link class="dx-link" navigate={~p"/applications/#{@name}/ghosted"}>Ghosted versions</.link>
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :relup, :map, required: true

  # What a hot upgrade did, under the row it was opened from: the steps the node ran with what
  # each one means, then the outcome, or the relup itself as text to copy
  defp relup_panel(assigns) do
    ~H"""
    <div
      id="relup"
      role="region"
      aria-labelledby="relup-h"
      class="border-t border-(--dx-base-300) bg-(--dx-base-200) px-5 py-4"
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h3 id="relup-h" class="text-[0.9375rem] font-bold">
          Relup · {@relup.from} → {@relup.to}
        </h3>
        <div class="flex flex-wrap items-center gap-3">
          <div :if={@relup.kept} class="dx-seg2" role="group" aria-label="Show the relup as">
            <button
              :for={{view, label} <- [steps: "Steps", original: "Original file"]}
              id={"relup-view-#{view}"}
              type="button"
              aria-pressed={to_string(@relup.view == view)}
              phx-click="relup_view"
              phx-value-view={view}
            >
              {label}
            </button>
          </div>
          <button
            id="relup-close"
            type="button"
            class="dx-link text-[0.875rem]"
            phx-click="close_relup"
          >
            Close
          </button>
        </div>
      </div>

      <p :if={is_nil(@relup.kept)} class="dx-muted mt-3 text-[0.875rem]">
        DeployEx has no relup for this hot upgrade. It keeps the newest ones of each application, and
        none from before it started keeping them.
      </p>

      <div :if={@relup.kept && @relup.view == :steps}>
        <p class="dx-muted mt-3 text-[0.8125rem]">
          What the node ran for this hot upgrade, in the order it ran it.
        </p>
        <ol id="relup-steps" class="mt-2">
          <li
            :for={step <- Map.get(@relup.kept, :steps, [])}
            class="grid grid-cols-[52px_minmax(0,1fr)] gap-x-3 border-t border-(--dx-base-300) py-2.5"
          >
            <span class="dx-mono dx-muted pt-0.5 text-[0.75rem]">{step_number(step)}</span>
            <div>
              <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
                <b class="dx-mono text-[0.8125rem]">{step.instruction}</b>
                <span
                  :for={option <- step.options}
                  class="dx-chip dx-mono px-1.5 py-px text-[0.6875rem]"
                >
                  {option}
                </span>
                <span :if={step.subject} class="dx-mono text-[0.8125rem]">{step.subject}</span>
                <span :if={length(step.targets) > 1} class="dx-muted text-[0.75rem]">
                  {length(step.targets)} modules
                </span>
              </div>
              <p :if={step.targets != []} class="dx-mono mt-1 text-[0.75rem] [overflow-wrap:anywhere]">
                {Enum.join(step.targets, ", ")}
              </p>
              <p class="dx-muted mt-1 text-[0.8125rem]">{Relup.explain(step)}</p>
            </div>
          </li>
        </ol>
        <h4 class="mt-2 border-t border-(--dx-base-300) pt-3 text-[0.875rem] font-bold">Outcome</h4>
        <ul id="relup-outcome" class="mt-2 flex flex-col gap-1.5 text-[0.875rem]">
          <li :for={line <- relup_lines(@relup.kept)}>{line}</li>
        </ul>
      </div>

      <div :if={@relup.kept && @relup.view == :original}>
        <div class="mt-3 flex flex-wrap items-center justify-between gap-3">
          <p class="dx-muted text-[0.8125rem]">
            The relup as DeployEx installed it, without the way back, which it never applies.
          </p>
          <button
            id="relup-copy"
            type="button"
            class="dx-btn min-h-8 text-[0.8125rem]"
            phx-click={JS.dispatch("dx:copy-text", detail: %{from: "#relup-text"})}
          >
            Copy
          </button>
        </div>
        <pre
          id="relup-text"
          class="dx-mono mt-3 max-h-[520px] overflow-auto rounded border border-(--dx-base-300) bg-(--dx-base-100) p-3 text-[0.75rem]"
        >{@relup.kept.text}</pre>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket), do: Status.subscribe()

    {:ok,
     socket
     |> assign(name: name, segment: nil, pick: nil, asking: false, current_path: "/applications")
     |> assign(:relup, nil)
     |> assign(:page_title, "#{name} versions and mode")
     |> load()}
  end

  @impl true
  def handle_params(params, _url, socket),
    do: {:noreply, assign(socket, :filter, params["sname"])}

  @impl true
  def handle_event("segment", %{"segment" => "automatic"}, socket),
    do: {:noreply, assign(socket, segment: :automatic, asking: false)}

  def handle_event("segment", %{"segment" => "pin"}, %{assigns: assigns} = socket),
    do:
      {:noreply,
       assign(socket, segment: :pin, asking: false, pick: assigns.pick || default_pick(assigns))}

  def handle_event("pick", %{"version" => version}, socket),
    do: {:noreply, assign(socket, pick: version, asking: false)}

  def handle_event("pick", _params, socket), do: {:noreply, socket}

  # The relup is read when it is asked for, it can be tens of kilobytes. It opens under the
  # row that asked, and the link of an open one closes it
  def handle_event("relup", %{"sname" => sname, "from" => from, "to" => to}, socket) do
    %{name: name, relup: open} = socket.assigns

    relup =
      if match?(%{sname: ^sname, from: ^from, to: ^to}, open) do
        nil
      else
        %{sname: sname, from: from, to: to, view: :steps, kept: Catalog.relup(name, from, to)}
      end

    {:noreply, assign(socket, :relup, relup)}
  end

  def handle_event("relup_view", %{"view" => view}, %{assigns: %{relup: %{} = relup}} = socket)
      when view in ["steps", "original"] do
    {:noreply, assign(socket, :relup, %{relup | view: String.to_existing_atom(view)})}
  end

  def handle_event("relup_view", _params, socket), do: {:noreply, socket}

  def handle_event("close_relup", _params, socket), do: {:noreply, assign(socket, :relup, nil)}

  def handle_event("ask", _params, socket), do: {:noreply, assign(socket, :asking, true)}
  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :asking, false)}

  def handle_event(
        "confirm",
        _params,
        %{assigns: %{segment: :pin, pick: version, name: name}} = socket
      ) do
    Status.set_mode(name, :manual, version)

    {:noreply,
     socket
     |> assign(asking: false, segment: nil)
     |> put_flash(:info, "#{name} is pinned to #{version}")
     |> load()}
  end

  def handle_event("confirm", _params, %{assigns: %{name: name}} = socket) do
    Status.set_mode(name, :automatic, "")

    {:noreply,
     socket
     |> assign(asking: false, segment: nil)
     |> put_flash(:info, "#{name} follows current.json")
     |> load()}
  end

  # The broadcast carries the statuses, and the history is read again only when the versions change
  @impl true
  def handle_info({:monitoring_app_updated, source_node, statuses}, socket)
      when source_node == node(),
      do: {:noreply, load(socket, statuses, :changed)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # A load after an action reads the statuses and the history again
  defp load(socket) do
    statuses =
      case connected?(socket) && Status.monitoring() do
        {:ok, statuses} -> statuses
        _ -> []
      end

    load(socket, statuses, :always)
  end

  defp load(%{assigns: %{name: name}} = socket, statuses, read) do
    found = find_app(statuses, name)
    app = found || %Status{name: name, config: %{}}
    children = app.children
    versions = Map.get(app.config, :versions, [])
    currents = Map.new(children, &{&1.sname, &1.version})

    history =
      if read == :changed and socket.assigns[:read_for] == {versions, currents},
        do: socket.assigns.history,
        else: history(socket, found)

    pinned = pinned(app.config)

    socket =
      socket
      |> assign(:language, app.language)
      |> assign(:logo, Enum.find_value(app.children, & &1.logo))
      |> assign(:timing, timing(app))
      |> assign(:snames, Enum.map(children, & &1.sname))
      |> assign(:count, max(app.replicas, length(children)))
      |> assign(:currents, currents)
      |> assign(:current, children |> Enum.map(& &1.version) |> Enum.find(& &1))
      |> assign(:pinned, pinned)
      |> assign(:versions, versions)
      |> assign(:history, history)
      |> assign(:read_for, {versions, currents})
      |> assign(:now, DateTime.utc_now())

    socket
    |> assign(:segment, socket.assigns.segment || if(pinned, do: :pin, else: :automatic))
    |> assign(:pick, socket.assigns.pick || pinned || default_pick(socket.assigns))
  end

  # The app's status, or nil when this host does not run it, or before the first reading
  defp find_app(statuses, name) do
    case Enum.find(statuses, &(&1.name == name)) do
      %{config: config} = app when is_map(config) -> app
      app when is_map(app) -> %{app | config: %{}}
      nil -> nil
    end
  end

  # An app this host does not run, like a mistyped name in the URL, has no catalog to read
  defp history(socket, %Status{name: name}),
    do: if(connected?(socket), do: Status.history_version_list(name, []), else: [])

  defp history(_socket, nil), do: []

  defp pinned(%{mode: :manual, manual_version: %{version: version}}), do: version
  defp pinned(_config), do: nil

  defp default_pick(%{versions: [latest | _] = versions, current: current}),
    do: Enum.find(versions, latest, &(&1 != current))

  defp default_pick(_assigns), do: nil

  defp changing?(:pin, pick, pinned), do: pick != pinned
  defp changing?(:automatic, _pick, pinned), do: pinned != nil
  defp changing?(_segment, _pick, _pinned), do: false

  # The newest record of each instance with the instance's running version is its current one
  defp rows(history, filter, currents, now) do
    {rows, _seen} =
      history
      |> Enum.filter(&(is_nil(filter) or &1.sname == filter))
      |> Enum.map_reduce(MapSet.new(), fn version, seen ->
        current =
          version.version == currents[version.sname] and not MapSet.member?(seen, version.sname)

        at = version.inserted_at && DateTime.from_naive!(version.inserted_at, "Etc/UTC")

        row = %{
          version: version.version,
          sname: version.sname,
          deployment: version.deployment,
          from: from(version),
          config_change: config_change(version),
          current: current,
          at: at && HostTime.format(at, "%Y-%m-%d %H:%M"),
          age: View.age(at, now)
        }

        {row, MapSet.put(seen, version.sname)}
      end)

    rows
  end

  defp mode_text(nil, _count),
    do: "DeployEx deploys the version that current.json names in the release bucket."

  defp mode_text(pinned, count),
    do:
      "DeployEx keeps #{every(count)} on #{pinned} and does not follow current.json until you set Automatic again."

  defp ask_text(:pin, name, pick, _current, count),
    do:
      "Pin #{name} to #{pick}? DeployEx deploys #{pick} to #{every(count)} and stops following current.json."

  defp ask_text(_segment, name, _pick, _current, _count),
    do: "Set #{name} to Automatic? DeployEx deploys the version in current.json, if it differs."

  # What the release asked for in current.json. Only a release that asked got config_change/3
  # forced. A record written by a version without the field reads as not set
  defp config_change(version) do
    case Map.get(version, :hot_upgrade_config_change) do
      true -> "requested"
      false -> "declined"
      _unset -> "not set"
    end
  end

  # The version a hot upgrade started from, which names its relup. A record written by a
  # version without the field has none
  defp from(%{deployment: :hot_upgrade} = version), do: Map.get(version, :from_version)
  defp from(_version), do: nil

  defp open?(%{sname: sname, from: from, to: to}, %{sname: sname, from: from, version: to}),
    do: true

  defp open?(_relup, _row), do: false

  # A step that stands for several instructions shows their range
  defp step_number(%{first: first, last: first}), do: "#{first}"
  defp step_number(%{first: first, last: last}), do: "#{first}–#{last}"

  # What the upgrade did, one line for each thing it did
  defp relup_lines(%{summary: summary} = kept) do
    applications =
      Enum.map_join(summary.applications, ", ", fn {name, version} -> "#{name} #{version}" end)

    [
      "Replaces code in #{count(length(summary.applications), "application")}: #{applications}",
      "Loads #{count(summary.modules, "module")}",
      summary.updated != [] &&
        "Suspends the processes of #{Enum.join(summary.updated, ", ")} and runs their code_change",
      summary.removed != [] && "Removes #{Enum.join(summary.removed, ", ")}",
      summary.applies != [] && "Calls #{Enum.join(summary.applies, ", ")}",
      summary.runtime_config &&
        "Applies the runtime configuration, with the config_change marker when the release asked for it",
      # A relup kept before this instruction existed has no such key
      Map.get(summary, :version_update, false) &&
        "Moves the version on traces and logs to the new one",
      version_update_lines(kept),
      Map.get(summary, :pipelines, false) &&
        "Stops the Broadway pipelines while the code is replaced, and starts them again",
      pipelines_line(kept),
      summary.restart_emulator && "Restarts the VM",
      "#{count(summary.instructions, "instruction")} in all"
    ]
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
  end

  # What that instruction did on the node, read back once the release was installed
  defp version_update_lines(%{version_update: %{} = result} = kept),
    do: VersionUpdate.describe(result, kept.from_version, kept.to_version)

  defp version_update_lines(_kept), do: []

  # What happened to each pipeline, read back once the release was installed
  defp pipelines_line(%{pipelines: results}) when is_list(results),
    do: "Pipelines: #{Pipelines.describe(results)}"

  defp pipelines_line(_kept), do: nil

  defp count(1, noun), do: "1 #{noun}"
  defp count(number, noun), do: "#{number} #{noun}s"

  # How often DeployEx checks for a new version, and how long a new version has to reach running
  defp timing(%{deploy_schedule_interval_ms: every, deploy_rollback_timeout_ms: within})
       when is_integer(every) and every > 0 and is_integer(within) and within > 0,
       do:
         "DeployEx checks for a new version every #{View.duration(every)}. A new version that is not " <>
           "running within #{View.duration(within)} is ghosted, and the instance goes back to the version before it."

  defp timing(_app), do: nil

  defp every(0), do: "its instances"
  defp every(1), do: "the instance"
  defp every(2), do: "both instances"
  defp every(count), do: "all #{count} instances"

  defp instances(1), do: "1 instance"
  defp instances(count), do: "#{count} instances"

  defp suffix(sname), do: sname |> String.split("-") |> List.last()

  defp retention do
    case Application.get_env(:foundation, :releases_retention) do
      value when is_integer(value) -> max(value, 2)
      _ -> 2
    end
  end
end
