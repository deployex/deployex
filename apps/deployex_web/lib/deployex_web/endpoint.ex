defmodule DeployexWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :deployex_web

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_deployex_web_key",
    signing_salt: "+VuBF/42",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # Assets are digested in production (see config/prod.exs). A page that was
  # opened before a hot upgrade still requests the file names it loaded, so the
  # release has to ship the digested files of the version it upgrades from.
  # phx.digest keeps the ones it finds in priv/static, which is why a hot
  # upgrade release builds both versions in the same directory.
  plug Plug.Static,
    at: "/",
    from: :deployex_web,
    gzip: false,
    only: DeployexWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId

  plug Plug.Telemetry,
    event_prefix: [:phoenix, :endpoint],
    log: {DeployexWeb.Logger, :log, []}

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug DeployexWeb.Router
end
