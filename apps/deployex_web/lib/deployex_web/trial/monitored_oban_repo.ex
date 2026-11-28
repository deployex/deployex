defmodule DeployexWeb.Trial.MonitoredObanRepo do
  @moduledoc """
  TRIAL ONLY - not part of the real feature.

  A plain Ecto Repo pointed at a monitored app's own Postgres database, used to
  validate that Oban Web can read/control that app's Oban instance with no
  Erlang RPC to the app's node - everything goes through Postgres instead
  (direct SQL reads plus Oban's LISTEN/NOTIFY channel).
  """

  use Ecto.Repo,
    otp_app: :deployex_web,
    adapter: Ecto.Adapters.Postgres
end
