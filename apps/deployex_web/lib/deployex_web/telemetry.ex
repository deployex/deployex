defmodule DeployexWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      # Scraped at GET /metrics, see DeployexWeb.MetricsController. A separate metric list
      # from metrics/0: this reporter has no Summary, which is what metrics/0 is made of
      {TelemetryMetricsPrometheus.Core, metrics: prometheus_metrics()}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  @doc """
  Metrics for GET /metrics, in Prometheus exposition format.

  Telemetry.Metrics.Summary, which metrics/0 is made of, has no Prometheus equivalent and
  `TelemetryMetricsPrometheus.Core` skips it with a warning, so this is its own list, of the
  types the reporter has: Counter, Sum, LastValue and Distribution (a histogram). A
  distribution needs bucket boundaries, and the unit of a histogram or a gauge belongs in its
  name, which is why these names and the ones in metrics/0 read the same event differently.
  """
  def prometheus_metrics do
    [
      # The request latency of the dashboard and the Agent API, by route
      distribution("phoenix.router_dispatch.stop.duration.seconds",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:route],
        reporter_options: [buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]]
      ),
      sum("phoenix.socket_drain.count"),

      # VM Metrics. The measurements come from the default, always-on poller of
      # :telemetry_poller itself, not from periodic_measurements/0 below
      last_value("vm.memory.total.bytes",
        event_name: [:vm, :memory],
        measurement: :total,
        unit: :byte
      ),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {DeployexWeb, :count_users, []}
    ]
  end
end
