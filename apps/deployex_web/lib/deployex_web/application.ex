defmodule DeployexWeb.Application do
  @moduledoc false

  use Application

  require Logger

  alias DeployexWeb.AgentApi.Tokens
  alias DeployexWeb.OAuth.Config

  ### ==========================================================================
  ### Callback Functions
  ### ==========================================================================
  @impl true
  def start(_type, _args) do
    Config.warn_if_incomplete()
    Tokens.warn_if_misconfigured()

    children = [
      DeployexWeb.Cache,
      DeployexWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:deployex_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DeployexWeb.PubSub},
      # Shell sessions outlive the page that opened them
      {Registry, keys: :unique, name: DeployexWeb.Shell.Registry},
      {DynamicSupervisor, name: DeployexWeb.Shell.Supervisor, strategy: :one_for_one},
      # Start the Finch HTTP client for sending emails
      {Finch, name: DeployexWeb.Finch},
      # TRIAL ONLY - one facade repo + one dashboard-only Oban instance per "monitored app" -
      # see DeployexWeb.Trial.MonitoredObanRepo
      DeployexWeb.Trial.MonitoredObanRepo,
      {Oban,
       Application.fetch_env!(:deployex_web, DeployexWeb.Trial.MonitoredOban)
       |> Keyword.put(:name, DeployexWeb.Trial.MonitoredOban)},
      DeployexWeb.Trial.MyphoenixappObanRepo,
      {Oban,
       Application.fetch_env!(:deployex_web, DeployexWeb.Trial.MyphoenixappOban)
       |> Keyword.put(:name, DeployexWeb.Trial.MyphoenixappOban)},
      # Start a worker by calling: DeployexWeb.Worker.start_link(arg)
      # {DeployexWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      DeployexWeb.Endpoint,
      DeployexWeb.AgentApi.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DeployexWeb.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = response ->
        notify_finish_deployment()
        response

      {:error, reason} = response ->
        Logger.error("Error Initializing DeployexWeb Application reason: #{inspect(reason)}")
        response
    end
  end

  ### ==========================================================================
  ### Private Functions
  ### ==========================================================================
  defp notify_finish_deployment do
    Foundation.Notifications.notify("deployment_complete", %{
      node: node(),
      sname: "deployex",
      status: :ok,
      message: "deployment completed with success"
    })
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DeployexWeb.Endpoint.config_change(changed, removed)
    DeployexWeb.AgentApi.Endpoint.config_change(changed, removed)
    :ok
  end
end
