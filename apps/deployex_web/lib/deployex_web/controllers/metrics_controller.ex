defmodule DeployexWeb.MetricsController do
  use DeployexWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4", "utf-8")
    |> send_resp(200, TelemetryMetricsPrometheus.Core.scrape())
  end
end
