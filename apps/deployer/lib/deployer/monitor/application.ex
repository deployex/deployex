defmodule Deployer.Monitor.Application do
  @moduledoc """
  GenServer that monitor and supervise the application.
  """
  use GenServer
  require Logger

  alias Deployer.Engine
  alias Deployer.Monitor
  alias Deployer.Status
  alias Foundation.Catalog
  alias Foundation.Common
  alias Foundation.Rpc
  alias Foundation.Yaml.Readiness
  alias Host.Commander

  @behaviour Monitor.Adapter

  @monitor_table "monitor-table"
  @new_deploy_topic "deployex::new_deploy"
  @max_backoff_ms :timer.minutes(5)
  # The restarts each instance keeps, for the dashboard
  @restart_history 10

  # What a restart says of an application that exited with no error
  @stopped_by_itself "stopped by itself"
  @readiness_check_interval :timer.seconds(1)

  ### ==========================================================================
  ### Callback functions
  ### ==========================================================================

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(%Monitor.Service{sname: sname} = service) do
    GenServer.start_link(__MODULE__, service, name: String.to_atom(sname))
  end

  @impl true
  def init(%Monitor.Service{sname: sname, language: language} = service) do
    Process.flag(:trap_exit, true)

    # NOTE: This ETS table provides non-blocking access to the state.
    :ets.new(table_name(sname), [:set, :protected, :named_table])

    Logger.info("Initializing monitor server for sname: #{sname} language: #{language}")

    trigger_run_service(sname)

    {:ok,
     update_non_blocking_state(%Monitor{
       # Map.get, since a DynamicSupervisor restart after a relup passes the start argument the
       # old code built, without a readiness key
       readiness: Map.get(service, :readiness, %Readiness{}),
       # Map.get for the same reason, a start argument without a secrets key
       secrets: Map.get(service, :secrets),
       retry_delay_pre_commands: service.retry_delay_pre_commands,
       name: service.name,
       sname: service.sname,
       ports: service.ports,
       language: language,
       env: service.env
     })}
  end

  @impl true
  def handle_call(
        :stop_service,
        _from,
        %Monitor{current_pid: current_pid, sname: sname} = state
      )
      when is_nil(current_pid) do
    Logger.warning("Requested sname: #{sname} to stop but application is not running.")

    {:reply, :ok, state}
  end

  def handle_call(
        :stop_service,
        _from,
        %Monitor{sname: sname, current_pid: pid} = state
      ) do
    Logger.info("Requested sname: #{sname} to stop application pid: #{inspect(pid)}")

    # Stop current application
    Commander.stop(state.current_pid)

    # NOTE: The next command is needed for Systems that have a different PID for the "/bin/app start" script
    #       and the bin/beam.smp process
    cleanup_beam_process(state.sname)

    # Without a current pid, the exit of the application that was just stopped is not taken
    # for one it decided by itself, which starts it again
    {:reply, :ok, %{state | current_pid: nil}}
  end

  def handle_call({:restart, _restart}, _from, state) when is_nil(state.current_pid) do
    {:reply, {:error, :application_is_not_running}, state}
  end

  def handle_call(:refresh_secrets, _from, state) do
    {:reply, refresh_secrets_on_node(state), state}
  end

  # A worker of the previous version, during a relup, still calls and installs whatever the reply
  # says. The commands run here the old blocking way, and a failure stops the monitor and its app,
  # as the old MatchError did, so that hot upgrade fails instead of installing
  def handle_call({:run_pre_commands, pre_commands, app_bin_service}, _from, state) do
    case execute_pre_commands(state, pre_commands, app_bin_service) do
      :ok ->
        {:reply, {:ok, pre_commands}, state}

      {:error, :pre_commands, _command} ->
        {:stop, :pre_commands_failed, {:error, :pre_commands}, state}
    end
  end

  # A restart waits for a running pre-commands run, as it did behind the old blocking call, so
  # the current version's pre_commands never run next to the new version's
  def handle_call({:restart, restart}, _from, %Monitor{pre_commands_run: %{} = run} = state) do
    Logger.warning("Restart requested for sname: #{state.sname}, after the running pre-commands")

    {:reply, :ok, %{state | pre_commands_run: Map.put(run, :restart, restart)}}
  end

  def handle_call({:restart, restart}, _from, state),
    do: {:reply, :ok, do_restart(state, restart)}

  # Hot upgrade pre_commands run as erlexec processes that report their exit with a DOWN message.
  # A hot upgrade needs a running app, so the worker asks again while it is down or starting
  @impl true
  def handle_cast(
        {:start_pre_commands, _pre_commands, _app_bin_service, from, ref},
        %Monitor{} = state
      )
      when state.current_pid == nil or state.status != :running do
    send(from, {:pre_commands_result, ref, {:error, :busy}})
    {:noreply, state}
  end

  # The is_map_key check covers a state that a relup could not update
  def handle_cast(
        {:start_pre_commands, pre_commands, app_bin_service, from, ref},
        %Monitor{} = state
      )
      when not is_map_key(state, :pre_commands_run) or state.pre_commands_run == nil do
    Logger.info(" # Migration executable: #{Catalog.bin_path(state.sname, app_bin_service)}")

    run = %{
      from: from,
      # A run nobody waits for is stopped, so it cannot hold the monitor busy
      from_ref: Process.monitor(from),
      ref: ref,
      pre_commands: pre_commands,
      remaining: pre_commands,
      bin_service: app_bin_service,
      command: nil,
      exec_pid: nil,
      os_pid: nil
    }

    # The worker learns the run started, so a timeout can tell it from a request never taken
    send(from, {:pre_commands_started, ref})

    {:noreply, run_next_pre_command(state, run)}
  end

  def handle_cast({:start_pre_commands, _pre_commands, _app_bin_service, from, ref}, state) do
    send(from, {:pre_commands_result, ref, {:error, :busy}})
    {:noreply, state}
  end

  def handle_cast(
        {:cancel_pre_commands, ref},
        %Monitor{pre_commands_run: %{ref: ref} = run} = state
      ) do
    Logger.warning("Stopping pre-command: #{run.command} for sname: #{state.sname}")
    Commander.stop(run.os_pid)

    {:noreply, end_pre_commands_run(state, run)}
  end

  def handle_cast({:cancel_pre_commands, _ref}, state), do: {:noreply, state}

  @impl true
  # A crash restart waits for a running pre-commands run too, see the restart clause
  def handle_info({:run_service, sname}, %Monitor{pre_commands_run: %{} = run} = state)
      when sname == state.sname do
    {:noreply, %{state | pre_commands_run: Map.put(run, :run_service, true)}}
  end

  def handle_info({:run_service, sname}, %Monitor{} = state)
      when sname == state.sname do
    version_map = Status.current_version_map(state.sname)
    version = version_map.version

    state =
      if version == nil do
        Logger.info("No version set, not able to run_service")
        state
      else
        Logger.info("Ensure running requested for sname: #{sname} version: #{version}")

        run_service(state, version_map)
      end

    {:noreply, update_non_blocking_state(state)}
  end

  def handle_info({:check_running, pid, sname}, state)
      when pid == state.current_pid and sname == state.sname do
    %{node: node} = Catalog.node_info(sname)

    if Monitor.Probe.ready?(readiness(state), node, state.language, state.ports) do
      Logger.info(" # Application sname: #{state.sname} is running")

      Engine.notify_application_running(sname)

      # NOTE: The application reached a stable state, so the backoff sequence starts
      #       over on the next crash. The crash_restart_count is a lifetime total and
      #       is never reset here.
      state = %{state | status: :running, consecutive_crash_count: 0}

      {:noreply, update_non_blocking_state(state)}
    else
      # The status stays :starting. For a deployment, the rollback timer of the engine worker is
      # the deadline, and it stops this monitor when the application never gets ready
      Logger.debug(" # Application sname: #{state.sname} is not ready yet")

      Process.send_after(self(), {:check_running, pid, sname}, @readiness_check_interval)

      {:noreply, state}
    end
  end

  def handle_info({:check_running, _pid, _sname}, state) do
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, os_pid, :process, _pid, :normal},
        %Monitor{pre_commands_run: %{os_pid: os_pid} = run} = state
      ) do
    {:noreply, run_next_pre_command(state, run)}
  end

  def handle_info(
        {:DOWN, os_pid, :process, _pid, reason},
        %Monitor{pre_commands_run: %{os_pid: os_pid} = run} = state
      ) do
    Logger.error(
      "Error running pre-command: #{run.command} for sname: #{state.sname} reason: #{inspect(reason)}"
    )

    notify_pre_command_failed(state, run.command, reason)
    send(run.from, {:pre_commands_result, run.ref, {:error, :pre_commands}})

    {:noreply, end_pre_commands_run(state, run)}
  end

  def handle_info(
        {:DOWN, from_ref, :process, _pid, _reason},
        %Monitor{pre_commands_run: %{from_ref: from_ref} = run} = state
      ) do
    Logger.warning(
      "Stopping pre-command: #{run.command} for sname: #{state.sname}, nobody waits for it"
    )

    Commander.stop(run.os_pid)

    {:noreply, end_pre_commands_run(state, run)}
  end

  # A pre-command that was cancelled, or another erlexec process that ended
  def handle_info({:DOWN, _os_pid, :process, _pid, _reason}, state), do: {:noreply, state}

  # The application ended by itself and with no error: it called System.stop/0, or the host
  # sent it a SIGTERM, which a node answers by shutting down and exiting with 0. Nobody
  # asked DeployEx for it, which clears the current pid before it stops the application
  # itself, so it is started again as after a crash
  def handle_info({:EXIT, pid, :normal}, %{current_pid: current_pid} = state)
      when is_pid(pid) and current_pid == pid do
    Logger.error(
      "Application sname: #{state.sname} with pid: #{inspect(pid)} stopped by itself, application being restarted"
    )

    {:noreply, restart_after_exit(state, @stopped_by_itself)}
  end

  def handle_info({:EXIT, _pid, :normal}, state) do
    # Ignore any erl_exec application that terminates normally, as this
    # occurs because the process is trapping all exits, including those
    # that are expected.
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, _reason}, %{current_pid: current_pid} = state)
      when current_pid == pid do
    Logger.error(
      "Unexpected exit message received for sname: #{state.sname} from pid: #{inspect(pid)}, application being restarted"
    )

    {:noreply, restart_after_exit(state, nil)}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning(
      "Application sname: #{state.sname} with pid: #{inspect(pid)} being stopped by reason: #{inspect(reason)}"
    )

    {:noreply, state}
  end

  # erlexec does not stop a command it only monitors when its owner exits
  @impl true
  def terminate(_reason, %Monitor{pre_commands_run: %{os_pid: os_pid}}) when is_integer(os_pid),
    do: Commander.stop(os_pid)

  def terminate(_reason, _state), do: :ok

  # A state from an older version gets the fields it lacks on a relup
  @impl true
  def code_change(_old_vsn, state, _extra) do
    {:ok,
     state
     |> Map.put_new(:pre_commands_run, nil)
     |> Map.put_new(:secrets, nil)
     |> Map.put_new(:reported_pre_commands, [])
     |> Map.put_new(:last_crash_at, nil)
     |> Map.put_new(:watchdog_restart_count, 0)
     |> Map.put_new(:restarts, [])
     |> Map.put_new_lazy(:started_at, fn -> Common.monotonic_to_utc(state.start_time) end)
     |> Map.put_new_lazy(:readiness, fn -> %Readiness{min_ready_ms: state.timeout_app_ready} end)
     |> Map.delete(:timeout_app_ready)}
  end

  ### ==========================================================================
  ### Public functions
  ### ==========================================================================
  @impl true
  def state(sname) do
    [{_, value}] =
      table_name(sname)
      |> :ets.lookup(:state)

    value
  rescue
    _ ->
      %Monitor{}
  end

  # The blocking call of the previous version, kept for its engine worker during a relup
  @impl true
  def run_pre_commands(sname, pre_commands, app_bin_service) do
    sname
    |> String.to_existing_atom()
    |> Common.call_gen_server({:run_pre_commands, pre_commands, app_bin_service})
  end

  @impl true
  def start_pre_commands(sname, pre_commands, app_bin_service) do
    case sname |> String.to_existing_atom() |> Process.whereis() do
      nil ->
        {:error, :not_running}

      pid ->
        # The monitor ref doubles as the request ref, so an exit mid-run reaches the caller
        ref = Process.monitor(pid)
        GenServer.cast(pid, {:start_pre_commands, pre_commands, app_bin_service, self(), ref})
        {:ok, ref}
    end
  end

  @impl true
  def cancel_pre_commands(sname, ref) do
    sname
    |> String.to_existing_atom()
    |> GenServer.cast({:cancel_pre_commands, ref})
  end

  # Reading the secret store can take much longer than the 5 seconds of a default call: three
  # requests to a Connect server, or the op command, and then the calls to the node. A caller
  # that gave up early would run the upgrade while the node is still being updated
  @refresh_secrets_call_timeout 120_000

  @impl true
  def refresh_secrets(sname), do: refresh_secrets(sname, @refresh_secrets_call_timeout)

  @doc """
  `refresh_secrets/1` with the time the monitor is given to answer, which a test shortens.
  """
  @spec refresh_secrets(String.t(), timeout()) :: :ok | {:error, any()}
  def refresh_secrets(sname, timeout) do
    sname
    |> String.to_existing_atom()
    |> GenServer.call(:refresh_secrets, timeout)
  rescue
    # No monitor was ever started under that name
    ArgumentError -> {:error, {:secrets, :monitor_not_answering}}
  catch
    # The reason of an exit holds the call, never a secret, and says nothing more useful
    :exit, _reason -> {:error, {:secrets, :monitor_not_answering}}
  end

  @impl true
  defdelegate start_service(service), to: Monitor.Supervisor

  @impl true
  defdelegate stop_service(name, sname), to: Monitor.Supervisor

  @impl true
  defdelegate list, to: Monitor.Supervisor

  @impl true
  defdelegate list(options), to: Monitor.Supervisor

  @impl true
  def subscribe_new_deploy do
    Phoenix.PubSub.subscribe(Deployer.PubSub, @new_deploy_topic)
  end

  @impl true
  def restart(sname, options \\ []) do
    restart = {Keyword.get(options, :cause, :operator), Keyword.get(options, :detail)}

    sname
    |> String.to_existing_atom()
    |> Common.call_gen_server({:restart, restart})
  end

  def global_name(sname),
    do: %{module: __MODULE__, sname: sname}

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================
  defp trigger_run_service(sname, timeout \\ 1),
    do: Process.send_after(self(), {:run_service, sname}, timeout)

  # Map.get, since a state that missed code_change on a relup has no readiness key
  defp readiness(state), do: Map.get(state, :readiness, %Readiness{})

  defp run_service(
         %Monitor{
           sname: sname,
           retry_delay_pre_commands: retry_delay_pre_commands
         } = state,
         version_map
       ) do
    app_exec = Catalog.bin_path(sname, :current)
    version = version_map.version

    notify_new_deploy = fn ->
      Foundation.Notifications.notify("deployment_started", %{
        node: Node.self(),
        sname: sname,
        version: version
      })

      Phoenix.PubSub.broadcast(
        Deployer.PubSub,
        @new_deploy_topic,
        {:new_deploy, Node.self(), sname}
      )
    end

    with true <- File.exists?(app_exec),
         {:ok, secret_env} <- secret_env(state),
         :ok <- notify_new_deploy.(),
         :ok <- Logger.info(" # Identified executable: #{app_exec}"),
         :ok <- execute_pre_commands(state, version_map.pre_commands, :current, secret_env) do
      Logger.info(" # Starting application")

      {:ok, pid, os_pid} =
        Commander.run_link(
          run_app_bin(state, app_exec, "start"),
          [
            {:env, os_env(secret_env)},
            {:stdout, Catalog.stdout_path(sname) |> to_charlist, [:append, {:mode, 0o600}]},
            {:stderr, Catalog.stderr_path(sname) |> to_charlist, [:append, {:mode, 0o600}]}
          ]
        )

      Logger.info(
        " # Running sname: #{sname}, monitoring pid = #{inspect(pid)}, OS process = #{os_pid} sname: #{sname}"
      )

      Process.send_after(self(), {:check_running, pid, sname}, readiness(state).min_ready_ms)

      # Map.put, since a state that missed code_change on a relup has no started_at key. The pre_commands
      # passed, so a later failure starts a new run of reports
      %{state | current_pid: pid, status: :starting, start_time: now()}
      |> Map.put(:started_at, DateTime.utc_now(:second))
      |> Map.put(:reported_pre_commands, [])
    else
      false ->
        trigger_run_service(sname, retry_delay_pre_commands)
        Logger.error("Version: #{version} set but no #{app_exec}")
        state

      # Starting without its secrets would only crash the application, so it waits and tries
      # again. The reason names the item, never a value
      {:error, {:secrets, reason}} ->
        trigger_run_service(sname, retry_delay_pre_commands)

        Logger.error(
          "Could not read the secrets of sname: #{sname}, not starting version: #{version}, " <>
            "reason: #{inspect(reason)}"
        )

        state

      {:error, :pre_commands, command} ->
        trigger_run_service(sname, retry_delay_pre_commands)
        reported = Enum.uniq([command | reported_pre_commands(state)])
        Map.put(%{state | status: :pre_commands}, :reported_pre_commands, reported)
    end
  end

  # NOTE: Some commands need to run prior starting the application
  #       - Unset env vars from the deployex release to not mix with the monitored app release
  #       - Unset DeployEx's own DEPLOYEX_* variables, which hold its secrets with the env adapter
  #       - Export RELEASE_NODE with sname
  #       - Export listening port that needs to be one per app
  defp run_app_bin(state, executable_path, command)

  defp run_app_bin(
         %{sname: sname, language: "elixir", ports: ports, env: env},
         executable_path,
         command
       ) do
    path = Common.remove_deployex_from_path()
    cookie = Common.cookie()
    app_env = build_export_command(env)

    ports_env =
      ports
      |> ports_to_env()
      |> build_export_command()

    # Set the distribution cookie, as the erlang and gleam clauses do. Without it the app
    # boots with its release default and DeployEx cannot connect over distribution when it
    # runs with a non-default cookie. It goes before app_env, so a RELEASE_COOKIE in the
    # app's env still wins.
    """
    #{limit_open_files()}
    unset $(env | grep -E '^(RELEASE|DEPLOYEX)_' | awk -F'=' '{print $1}')
    unset BINDIR ELIXIR_ERL_OPTIONS ROOTDIR
    export RELEASE_COOKIE=#{Common.shell_quote(cookie)}
    #{app_env}
    #{ports_env}
    export PATH=#{path}
    #{Common.release_node_env(sname)}
    #{executable_path} #{command}
    """
  end

  defp run_app_bin(
         %{sname: sname, language: "erlang", ports: ports, env: env},
         executable_path,
         "start"
       ) do
    path = Common.remove_deployex_from_path()
    cookie = Common.cookie()
    app_env = build_export_command(env)

    ports_env =
      ports
      |> ports_to_env()
      |> build_export_command()

    ssl_options =
      if Common.mtls_certificate() do
        "-proto_dist inet_tls -ssl_dist_optfile /tmp/inet_tls.conf"
      else
        ""
      end

    """
    #{limit_open_files()}
    unset $(env | grep -E '^(RELEASE|DEPLOYEX)_' | awk -F'=' '{print $1}')
    unset BINDIR ELIXIR_ERL_OPTIONS ROOTDIR
    #{app_env}
    #{ports_env}
    export PATH=#{path}
    export RELX_REPLACE_OS_VARS=true
    #{Common.release_node_env(sname)}
    export RELEASE_COOKIE=#{Common.shell_quote(cookie)}
    export RELEASE_SSL_OPTIONS=\"#{ssl_options}\"
    #{executable_path} foreground
    """
  end

  defp run_app_bin(
         %{sname: sname, language: "gleam", ports: ports, env: env},
         executable_path,
         "start"
       ) do
    %{name: name} = Catalog.node_info(sname)
    path = Common.remove_deployex_from_path()
    cookie = Common.cookie()
    app_env = build_export_command(env)

    ports_env =
      ports
      |> ports_to_env()
      |> build_export_command()

    ssl_options =
      if Common.mtls_certificate() do
        "-proto_dist inet_tls -ssl_dist_optfile /tmp/inet_tls.conf"
      else
        ""
      end

    """
    #{limit_open_files()}
    unset $(env | grep -E '^(RELEASE|DEPLOYEX)_' | awk -F'=' '{print $1}')
    unset BINDIR ELIXIR_ERL_OPTIONS ROOTDIR
    #{app_env}
    #{ports_env}
    export PATH=#{path}
    PACKAGE=#{name}
    BASE=#{executable_path}
    erl \
      -pa "$BASE"/*/ebin \
      -eval "$PACKAGE@@main:run($PACKAGE)" \
      -noshell \
      #{ssl_options} \
      #{Common.erl_name_argument(sname)} \
      -setcookie #{Common.shell_quote(cookie)}
    """
  end

  defp run_app_bin(%{sname: sname, language: language}, _executable_path, command) do
    msg =
      "Running not supported for language: #{language}, sname: #{sname}, command: #{command}"

    Logger.warning(msg)
    "echo \"#{msg}\""
  end

  # The Erlang VM sizes its table of ports from the limit of open files, unless it is
  # started with +Q. Where that limit is about a billion, in a Kubernetes pod on containerd
  # or under a systemd unit with LimitNOFILE=infinity on a recent kernel, the VM of an
  # application that has no +Q asks for gigabytes when it boots, and is killed where
  # memory is limited. A limit above the cap is lowered to it for the application and what
  # it starts. One that is at or below it is kept, so a host as it was is not changed.
  @max_open_files 1_048_576

  defp limit_open_files do
    ~s(if [ "$\(ulimit -n\)" = "unlimited" ] || [ "$\(ulimit -n\)" -gt #{@max_open_files} ]; ) <>
      "then ulimit -n #{@max_open_files}; fi"
  end

  defp ports_to_env(ports), do: Enum.map(ports, fn port -> "#{port.key}=#{port.base}" end)

  # The credentials DeployEx itself reads 1Password with. A monitored application starts as a
  # child of DeployEx and would inherit them
  @onepassword_env ~w(OP_CONNECT_HOST OP_CONNECT_TOKEN OP_SERVICE_ACCOUNT_TOKEN)

  # The environment handed to the OS process, on top of what run_app_bin/3 exports. The
  # secrets go this way and not through the command, which is visible in the process list.
  # A secret is set after the unset of the same name, so an application that has its own
  # 1Password credentials among its secrets keeps them
  defp os_env(secret_env) do
    Enum.map(@onepassword_env, &{&1, false}) ++ secret_env
  end

  # The secrets of the application, read again at every start, so a value changed in the
  # secret store reaches the application at its next restart. They are kept out of the state,
  # which is mirrored in a table that other processes read. The process dictionary is read
  # too, the process page of the dashboard prints it, so what is kept there is a function
  # that returns them, which prints as a function
  @secret_env_key {__MODULE__, :secret_env}

  defp secret_env(state) do
    case Map.get(state, :secrets) do
      nil ->
        {:ok, []}

      %{adapter: adapter, path: path} ->
        case adapter.application_env(path) do
          {:ok, env} ->
            Process.put(@secret_env_key, fn -> env end)
            {:ok, env}

          {:error, reason} ->
            cached_secret_env(state, reason)
        end
    end
  end

  # A restart after a crash must not depend on the secret store being reachable right then
  defp cached_secret_env(%{sname: sname}, reason) do
    case Process.get(@secret_env_key) do
      nil ->
        {:error, {:secrets, reason}}

      kept when is_function(kept, 0) ->
        Logger.warning(
          "Could not read the secrets of sname: #{sname}, using the ones from its last " <>
            "start, reason: #{inspect(reason)}"
        )

        {:ok, kept.()}
    end
  end

  @refresh_secrets_timeout 15_000

  # An application without secrets has nothing to refresh
  defp refresh_secrets_on_node(state) do
    if Map.get(state, :secrets) do
      # What the node was last given, read before secret_env/1 replaces it
      previous = kept_secret_env()

      case secret_env(state) do
        {:ok, env} ->
          {result, on_node} = put_secret_env_on_node(state, env, previous || [])
          # What the node holds now is what the next refresh compares with
          keep_secret_env(if(result == :ok, do: on_node, else: previous && on_node))
          result

        {:error, _reason} = error ->
          keep_secret_env(previous)
          error
      end
    else
      :ok
    end
  end

  # The environment of the running node is set from inside it, with functions of Erlang, so
  # it works for an Erlang or a Gleam node too, which has no Elixir. A secret that left the
  # secret store is removed, so the new version does not read a value that no longer exists.
  #
  # It answers with what the node holds afterwards. When the secrets were set and the ones
  # that left could not be removed, those are still on the node and stay in that list, so
  # the next refresh removes them
  defp put_secret_env_on_node(%{sname: sname} = state, env, previous) do
    %{node: node} = Catalog.node_info(sname)
    reserved = reserved_names(state)
    refresh = Enum.reject(env, fn {name, _value} -> name in reserved end)
    left = Enum.reject(previous, fn {name, _value} -> List.keymember?(env, name, 0) end)
    removed = for {name, _value} <- left, name not in reserved, do: name

    with :ok <- put_env_on_node(node, refresh),
         :ok <- unset_env_on_node(node, removed) do
      {:ok, env}
    else
      {:error, :not_set} -> {{:error, {:secrets, :node_not_updated}}, previous}
      {:error, :not_removed} -> {{:error, {:secrets, :node_not_updated}}, env ++ left}
    end
  end

  # The result of a failed call can hold its arguments, which are the secrets, so it is not
  # passed on
  defp put_env_on_node(_node, []), do: :ok

  defp put_env_on_node(node, env) do
    {names, values} = env |> Enum.map(&charlists/1) |> Enum.unzip()

    case Rpc.call(
           node,
           :lists,
           :zipwith,
           [&:os.putenv/2, names, values],
           @refresh_secrets_timeout
         ) do
      set when is_list(set) -> :ok
      _failed -> {:error, :not_set}
    end
  end

  defp unset_env_on_node(_node, []), do: :ok

  defp unset_env_on_node(node, names) do
    names = Enum.map(names, &String.to_charlist/1)

    case Rpc.call(node, :lists, :foreach, [&:os.unsetenv/1, names], @refresh_secrets_timeout) do
      :ok -> :ok
      _failed -> {:error, :not_removed}
    end
  end

  defp charlists({name, value}), do: {String.to_charlist(name), String.to_charlist(value)}

  # What the run script of the application exports after the secrets are in its environment:
  # the env and the ports of the YAML, and PATH. At a start those win over a secret with the
  # same name, so a refresh neither sets nor removes them
  defp reserved_names(state) do
    yaml_env = for entry <- Map.get(state, :env) || [], do: entry |> String.split("=") |> hd()
    ports = for port <- Map.get(state, :ports) || [], do: to_string(port.key)

    ["PATH" | yaml_env ++ ports]
  end

  defp kept_secret_env do
    case Process.get(@secret_env_key) do
      kept when is_function(kept, 0) -> kept.()
      _nothing_kept -> nil
    end
  end

  defp keep_secret_env(nil), do: Process.delete(@secret_env_key)
  defp keep_secret_env(env), do: Process.put(@secret_env_key, fn -> env end)

  defp build_export_command([]), do: ""

  # Quote each value, so spaces and shell characters reach the monitored app as written
  defp build_export_command(env_list) do
    Enum.reduce(env_list, "export ", fn env, acc ->
      acc <> "#{quote_env_value(env)} "
    end)
  end

  defp quote_env_value(env) do
    case String.split(env, "=", parts: 2) do
      [key, value] -> "#{key}=#{Common.shell_quote(value)}"
      [key] -> key
    end
  end

  defp execute_pre_commands(state, pre_commands, bin_service, secret_env \\ [])

  defp execute_pre_commands(_state, pre_commands, _bin_service, _secret_env)
       when pre_commands == [],
       do: :ok

  defp execute_pre_commands(
         %{sname: sname, status: status} = state,
         pre_commands,
         bin_service,
         secret_env
       ) do
    migration_exec = Catalog.bin_path(sname, bin_service)

    update_non_blocking_state(%{state | status: :pre_commands})

    Logger.info(" # Migration executable: #{migration_exec}")

    Enum.reduce_while(pre_commands, :ok, fn pre_command, acc ->
      Logger.info(" # Executing: #{pre_command}")

      Commander.run(run_app_bin(state, migration_exec, pre_command), [
        :sync,
        {:env, os_env(secret_env)},
        {:stdout, Catalog.stdout_path(sname) |> to_charlist, [:append, {:mode, 0o600}]},
        {:stderr, Catalog.stderr_path(sname) |> to_charlist, [:append, {:mode, 0o600}]}
      ])
      |> case do
        {:ok, _} ->
          {:cont, acc}

        {:error, reason} ->
          Logger.error(
            "Error running pre-command: #{pre_command} for sname: #{sname} reason: #{inspect(reason)}"
          )

          # A retry sends nothing for a pre_command this run of failures already reported
          if pre_command not in reported_pre_commands(state),
            do: notify_pre_command_failed(state, pre_command, reason)

          {:halt, {:error, :pre_commands, pre_command}}
      end
    end)
    |> tap(fn _response -> update_non_blocking_state(%{state | status: status}) end)
  end

  # A hot upgrade needs the app up. When it went down, or a restart waits on the run, the reply
  # says the pre_commands ran, so the worker waits for the app without running them again
  defp run_next_pre_command(state, %{remaining: []} = run) do
    app_down? = state.current_pid == nil or state.status != :running

    result =
      if run[:restart] || run[:run_service] || app_down?,
        do: {:error, :app_down},
        else: {:ok, run.pre_commands}

    send(run.from, {:pre_commands_result, run.ref, result})

    end_pre_commands_run(state, run)
  end

  defp run_next_pre_command(%Monitor{sname: sname} = state, %{remaining: [command | rest]} = run) do
    Logger.info(" # Executing: #{command}")

    with {:ok, secret_env} <- secret_env(state) do
      state
      |> run_app_bin(Catalog.bin_path(sname, run.bin_service), command)
      |> Commander.run([
        :monitor,
        # Its own process group, so a stop also ends the BEAM that `bin/app eval` starts
        {:group, 0},
        :kill_group,
        {:env, os_env(secret_env)},
        {:stdout, Catalog.stdout_path(sname) |> to_charlist, [:append, {:mode, 0o600}]},
        {:stderr, Catalog.stderr_path(sname) |> to_charlist, [:append, {:mode, 0o600}]}
      ])
    end
    |> case do
      {:ok, exec_pid, os_pid} ->
        run = %{run | remaining: rest, command: command, exec_pid: exec_pid, os_pid: os_pid}
        state = Map.put(state, :pre_commands_run, run)

        # The dashboard shows the migration, the application itself keeps its status
        update_non_blocking_state(%{state | status: :pre_commands})
        state

      {:error, reason} ->
        Logger.error(
          "Error running pre-command: #{command} for sname: #{sname} reason: #{inspect(reason)}"
        )

        notify_pre_command_failed(state, command, reason)
        send(run.from, {:pre_commands_result, run.ref, {:error, :pre_commands}})
        end_pre_commands_run(state, run)
    end
  end

  defp end_pre_commands_run(state, %{from_ref: from_ref} = run) do
    Process.demonitor(from_ref, [:flush])
    state = update_non_blocking_state(Map.put(state, :pre_commands_run, nil))

    # do_restart schedules run_service itself. A restart for an application that is already
    # down is dropped, its crash restart has its own run_service
    cond do
      run[:restart] && state.current_pid != nil ->
        do_restart(state, run.restart)

      run[:run_service] ->
        trigger_run_service(state.sname)
        state

      true ->
        state
    end
  end

  # Only a pass moves the status off :pre_commands, so the next failure starts a new run
  defp reported_pre_commands(%Monitor{status: :pre_commands} = state),
    do: Map.get(state, :reported_pre_commands, [])

  defp reported_pre_commands(_state), do: []

  # The reason is inspected, so every adapter can encode it
  defp notify_pre_command_failed(%Monitor{} = state, command, reason) do
    Foundation.Notifications.notify("pre_command_failed", %{
      node: Node.self(),
      sname: state.sname,
      name: state.name,
      command: command,
      reason: inspect(reason)
    })
  end

  # The application is down and nobody asked for it: it is started again, after a backoff
  # that grows with the crashes in a row
  defp restart_after_exit(state, detail) do
    cleanup_beam_process(state.sname)

    # Update the number of crash restarts
    crash_restart_count = state.crash_restart_count + 1

    # Crashes since the application was last seen running. The backoff and the engine worker's
    # crash-loop check for a hot upgrade read it
    consecutive_crash_count = state.consecutive_crash_count + 1

    Foundation.Notifications.notify("crash_restart", %{
      node: Node.self(),
      sname: state.sname,
      name: state.name,
      language: state.language,
      crash_restart_count: crash_restart_count
    })

    # Retry with backoff pattern, capped to avoid unbounded growth
    backoff = min(2 * consecutive_crash_count * 1000, @max_backoff_ms)
    trigger_run_service(state.sname, backoff)

    # Map.put, since a state that missed code_change on a relup has no last_crash_at key
    state =
      %{
        state
        | current_pid: nil,
          crash_restart_count: crash_restart_count,
          consecutive_crash_count: consecutive_crash_count
      }
      |> Map.put(:last_crash_at, DateTime.utc_now(:second))
      |> add_restart({:crash, detail})

    update_non_blocking_state(state)
  end

  defp do_restart(state, {cause, _detail} = restart) do
    Logger.warning("Restart requested for sname: #{state.sname}")

    Foundation.Notifications.notify("deployment_shutdown", %{
      node: node(),
      sname: "#{state.sname}"
    })

    # Stop current application
    Commander.stop(state.current_pid)

    cleanup_beam_process(state.sname)

    # Update the number of force restarts, and of the ones the watchdog asked for
    force_restart_count = state.force_restart_count + 1

    watchdog_restart_count =
      Map.get(state, :watchdog_restart_count, 0) + if(cause == :watchdog, do: 1, else: 0)

    # Trigger restart with backoff time of 1 second
    trigger_run_service(state.sname, 1_000)

    # The app is down until run_service starts it again. Without a current pid, its exit is not
    # taken for a crash, which would start it a second time
    %{state | current_pid: nil, force_restart_count: force_restart_count, status: :starting}
    |> Map.put(:watchdog_restart_count, watchdog_restart_count)
    |> add_restart(restart)
    |> update_non_blocking_state()
  end

  # The latest restarts, newest first. Map.update, since a state that missed code_change has no restarts
  defp add_restart(state, {cause, detail}) do
    restart = %{at: DateTime.utc_now(:second), cause: cause, detail: detail}
    Map.update(state, :restarts, [restart], &Enum.take([restart | &1], @restart_history))
  end

  defp cleanup_beam_process(sname) do
    %{sname: sname, name: name} = Catalog.node_info(sname)

    case Commander.run(
           "kill -9 $(ps -ax | grep \"#{name}/#{sname}/current/erts-*.*/bin/beam.smp\" | grep -v grep | awk '{print $1}') ",
           [:sync, :stdout, :stderr]
         ) do
      {:ok, _} ->
        Logger.warning("Remaining beam app removed for sname: #{sname}")

      {:error, _reason} ->
        # Logger.warning("Nothing to remove for sname: #{sname} - #{inspect(reason)}")
        :ok
    end
  end

  defp now, do: System.monotonic_time()

  defp table_name(sname), do: (@monitor_table <> "-#{sname}") |> String.to_atom()

  defp update_non_blocking_state(%{sname: sname} = state) do
    table_name(sname)
    |> :ets.insert({:state, state})

    state
  end
end
