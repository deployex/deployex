defmodule DeployexWeb.Trial.MyumbrellaResolver do
  @moduledoc """
  TRIAL ONLY - restricts this mount to a single Oban instance so Oban Web's own
  instance switcher never offers another app, and the browser's remembered last-picked
  instance (localStorage) can't leak across apps. See DeployexWeb.Trial.MonitoredObanRepo.
  """
  @behaviour Oban.Web.Resolver

  @impl true
  def resolve_instances(_user), do: [DeployexWeb.Trial.MonitoredOban]
end

defmodule DeployexWeb.Trial.MyphoenixappResolver do
  @moduledoc """
  TRIAL ONLY - see DeployexWeb.Trial.MyumbrellaResolver.
  """
  @behaviour Oban.Web.Resolver

  @impl true
  def resolve_instances(_user), do: [DeployexWeb.Trial.MyphoenixappOban]
end
