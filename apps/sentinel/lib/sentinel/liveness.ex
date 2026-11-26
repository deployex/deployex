defmodule Sentinel.Liveness do
  @moduledoc """
  Probes monitored applications after they are already ready, and reports or restarts one that
  stops answering.

  Liveness is opt-in per application, through the `liveness` YAML section, and off by default:
  an application with no section is never probed. It reuses `Deployer.Monitor.Probe`, the same
  module readiness uses, so the probe itself is identical to the one that gated the deployment.

  A probe only runs while the application's monitor reports `:running`, so an instance that
  crashed and is starting again, or one still running pre-commands, is neither probed nor
  counted as failing. Each instance is probed every `period_ms` of its configuration, on a
  tick of one second. A probe that fails `failure_threshold` times in a row sends a
  `"liveness_probe_failed"` notification once, and restarts the application through
  `Deployer.Monitor.restart/2` when the application's `enable_restart` opts into it. The BEAM
  already restarts a crashed process on its own, so the default is to only report a hung one:
  restarting every replica during a shared dependency outage would make the outage worse.

  Liveness probes should not check external dependencies, such as a database or cache. Those
  checks belong in readiness, where a version that cannot reach its dependencies at boot is
  ghosted instead of replacing a previous version that could.
  """

  use GenServer
  require Logger

  alias Deployer.Monitor
  alias Deployer.Monitor.Probe
  alias Foundation.Catalog
  alias Foundation.Notifications
  alias Foundation.Yaml.Liveness, as: LivenessConfig

  @liveness_check_interval :timer.seconds(1)
  @liveness_data :deployex_liveness_data

  defmodule Data do
    @moduledoc """
    How many liveness probes an sname has failed in a row, and whether that streak already
    sent a notification, so a hung application is reported only once per streak. The next
    probe is due at `next_probe_at`, in monotonic milliseconds, and `nil` means right away.
    """

    defstruct consecutive_failures: 0, notified: false, next_probe_at: nil

    @type t :: %__MODULE__{
            consecutive_failures: non_neg_integer(),
            notified: boolean(),
            next_probe_at: integer() | nil
          }
  end

  ### ==========================================================================
  ### GenServer Callbacks
  ### ==========================================================================
  def start_link(args) do
    name = Keyword.get(args, :name, __MODULE__)

    GenServer.start_link(__MODULE__, args, name: name)
  end

  @impl true
  def init(args) do
    Logger.info("Initializing Liveness Server")

    :ets.new(@liveness_data, [:set, :protected, :named_table])

    liveness_check_interval =
      Keyword.get(args, :liveness_check_interval, @liveness_check_interval)

    schedule_new_check(liveness_check_interval)

    {:ok, %{liveness_check_interval: liveness_check_interval}}
  end

  @impl true
  def handle_info(:liveness_check, %{liveness_check_interval: liveness_check_interval} = state) do
    # The list is read fresh on every check, rather than tracked through new-deploy events,
    # since it already reflects exactly the monitors currently running
    Monitor.list() |> Enum.each(&check_sname/1)

    schedule_new_check(liveness_check_interval)

    {:noreply, state}
  end

  ### ==========================================================================
  ### Private Functions
  ### ==========================================================================
  defp schedule_new_check(interval), do: Process.send_after(self(), :liveness_check, interval)

  defp check_sname(sname) do
    case Monitor.state(sname) do
      %Monitor{liveness: nil} ->
        :ok

      %Monitor{status: status} when status != :running ->
        reset(sname)

      %Monitor{liveness: liveness} = monitor ->
        now = System.monotonic_time(:millisecond)
        data = get_data(sname)

        if due?(data, now), do: probe(sname, monitor, data, now + liveness.period_ms)
    end
  end

  defp due?(%Data{next_probe_at: nil}, _now), do: true
  defp due?(%Data{next_probe_at: next_probe_at}, now), do: now >= next_probe_at

  defp probe(
         sname,
         %Monitor{liveness: liveness, language: language, name: name, ports: ports},
         data,
         next_probe_at
       ) do
    %{node: node} = Catalog.node_info(sname)

    if Probe.alive?(liveness, node, language, ports) do
      :ets.insert(@liveness_data, {sname, %Data{next_probe_at: next_probe_at}})
    else
      record_failure(sname, node, name, liveness, %{data | next_probe_at: next_probe_at})
    end
  end

  # An instance that is not running starts from scratch, probed as soon as it runs again
  defp reset(sname), do: :ets.insert(@liveness_data, {sname, %Data{}})

  defp record_failure(
         sname,
         node,
         name,
         %LivenessConfig{failure_threshold: failure_threshold, enable_restart: enable_restart},
         data
       ) do
    consecutive_failures = data.consecutive_failures + 1

    if consecutive_failures >= failure_threshold and not data.notified do
      report_hung(sname, node, name, consecutive_failures, failure_threshold, enable_restart)

      :ets.insert(
        @liveness_data,
        {sname, %{data | consecutive_failures: consecutive_failures, notified: true}}
      )
    else
      :ets.insert(@liveness_data, {sname, %{data | consecutive_failures: consecutive_failures}})
    end
  end

  defp get_data(sname) do
    case :ets.lookup(@liveness_data, sname) do
      [{_, data}] -> data
      [] -> %Data{}
    end
  end

  defp report_hung(sname, node, name, consecutive_failures, failure_threshold, enable_restart) do
    action = if enable_restart, do: :restart, else: :no_restart

    Logger.error(
      "[#{sname}] liveness probe failed #{consecutive_failures} times in a row, action=#{action}"
    )

    Notifications.notify("liveness_probe_failed", %{
      node: node,
      sname: sname,
      name: name,
      consecutive_failures: consecutive_failures,
      failure_threshold: failure_threshold,
      action: action
    })

    if enable_restart do
      Monitor.restart(sname,
        cause: :liveness,
        detail: "failed #{consecutive_failures} liveness probes"
      )
    end
  end
end
