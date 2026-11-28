defmodule DeployexWeb.Trial.MyphoenixappObanRepo do
  @moduledoc """
  TRIAL ONLY - second facade repo, pointed at a different monitored app's database, to prove
  the Oban Web instance switcher can pick between several apps with no code change per app
  beyond one small facade repo + one Oban config block. See DeployexWeb.Trial.MonitoredObanRepo.
  """

  use Ecto.Repo,
    otp_app: :deployex_web,
    adapter: Ecto.Adapters.Postgres
end
