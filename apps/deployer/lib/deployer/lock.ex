defmodule Deployer.Lock do
  @moduledoc """
  One deployment of an application at a time, across the DeployEx nodes that are connected.

  Where there is a DeployEx on each of several hosts, each one reads the version to run by
  itself, and without this they would all deploy it in the same second. An engine worker
  takes the lock of its application before it starts a deployment and gives it back when
  the deployment is over, so the hosts go one after the other and the others keep serving
  the version they have meanwhile. A DeployEx that is alone always gets it.

  An instance that runs nothing does not take it, the start of an application when DeployEx
  boots for instance: every host starts what it has.

  ## What it is made of

  The lock itself is a lock of `:global`, set on this node and on the DeployEx nodes it is
  connected to, and held by the engine worker. It is released when the worker or its node
  goes down, so no lock is left behind by a DeployEx that stopped.

  What `:global` does not keep is who holds a lock, for which deployment and since when.
  That is in a table of this node, which `list/0` reads and `fleet/0` reads from every
  connected DeployEx.

  ## A holder that never gives it back

  A lock says until when it can be held: the time the deployment has to be running, which
  is `deploy_rollback_timeout_ms` of the application, and a minute. A worker that finds the
  lock held after that deploys without it, and logs it. So does one that waited that long
  for a lock no connected DeployEx says it holds.

  `cancel/1` ends the deployment that holds the lock, which gives it back: the instance is
  returned to the version it had and the version it was moving to is ghosted on that host.

  ## After a hot upgrade of DeployEx

  The table is owned by a server that a hot upgrade to the first version with this module
  does not start. Without it every function answers as if no lock was ever held and the
  workers deploy as they did before, until DeployEx is restarted.
  """

  use GenServer

  require Logger

  alias Foundation.Peers

  @table __MODULE__
  @grace_ms :timer.minutes(1)
  @rpc_timeout 2_000

  @typedoc """
  A lock that is held or waited for on a node.

    * `state` - `:held`, `:waiting`, or `:forced` for a deployment that started without the
      lock because its holder kept it past `expires_at`
    * `since` and `expires_at` - system time in milliseconds
  """
  @type entry :: %{
          name: String.t(),
          state: :held | :waiting | :forced,
          node: node(),
          owner: pid(),
          sname: String.t() | nil,
          from_version: String.t() | nil,
          to_version: String.t() | nil,
          since: integer(),
          expires_at: integer()
        }

  ### ==========================================================================
  ### Public APIs
  ### ==========================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc """
  Takes the lock of the application `name` for the calling process, which is the one that
  holds it.

  `info` says what the deployment is: `sname`, `from_version`, `to_version`, and `hold_ms`,
  the time the deployment has to be running.

  Returns `:ok` when the caller can deploy: it has the lock, it had it already, or the
  holder kept it for too long. Returns `{:waiting, holder}` otherwise, `holder` being the
  entry of the lock that is in the way, or `nil` when no connected DeployEx says it holds it.
  """
  @spec acquire(String.t(), map()) :: :ok | {:waiting, entry() | nil}
  def acquire(name, info) do
    if table() do
      case entry(name) do
        %{state: state} when state in [:held, :forced] -> :ok
        waiting -> try_lock(name, info, waiting)
      end
    else
      :ok
    end
  end

  @doc """
  Gives the lock of the application `name` back, when the calling process holds it.
  """
  @spec release(String.t()) :: :ok
  def release(name) do
    with true <- table() != nil,
         %{state: state} <- entry(name) do
      if state == :held, do: :global.del_lock(lock_id(name, self()))
      :ets.delete(@table, {name, self()})
    end

    :ok
  end

  @doc """
  Whether the calling process deploys the application `name` with the lock, or without it
  after it was held for too long.
  """
  @spec held?(String.t()) :: boolean()
  def held?(name) do
    match?(%{state: state} when state in [:held, :forced], table() && entry(name))
  end

  @doc """
  The locks held and waited for on this node.
  """
  @spec list() :: [entry()]
  def list do
    if table(), do: @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)), else: []
  end

  @doc """
  The locks held and waited for on this node and on every DeployEx it is connected to.

  A node that does not answer is left out.
  """
  @spec fleet() :: [entry()]
  def fleet, do: Enum.sort_by(list() ++ peers_list(), &{&1.name, &1.since})

  @doc """
  Ends the deployment of the application `name` on `node`, which gives its lock back.

  The instance returns to the version it had, and the version it was moving to is ghosted
  on that host, as when a deployment does not get to run in time.
  """
  @spec cancel(node(), String.t()) :: :ok | {:error, term()}
  def cancel(node \\ Node.self(), name) do
    :erpc.call(node, Deployer.Engine.Worker, :cancel_deployment, [name], @rpc_timeout)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  ### ==========================================================================
  ### GenServer callbacks
  ### ==========================================================================

  @impl true
  def init(_options) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  # The entry of a worker that is gone goes with it. Its lock is released by :global
  @impl true
  def handle_cast({:monitor, owner}, state) do
    if Map.has_key?(state, owner) do
      {:noreply, state}
    else
      {:noreply, Map.put(state, owner, Process.monitor(owner))}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _reason}, state) do
    :ets.match_delete(@table, {:_, %{owner: owner}})
    {:noreply, Map.delete(state, owner)}
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp try_lock(name, info, waiting) do
    now = System.system_time(:millisecond)

    if :global.set_lock(lock_id(name, self()), [Node.self() | Peers.list()], 0) do
      put(name, :held, info, now)
      :ok
    else
      holder = holder(name)
      since = if waiting, do: waiting.since, else: now

      if expired?(holder, since, info, now) do
        Logger.warning(
          "The deployment lock of #{name} was not given back in time by " <>
            "#{describe(holder)}, deploying without it"
        )

        put(name, :forced, info, now)
        :ok
      else
        if is_nil(waiting) do
          Logger.info("Deployment of #{name} waits for the one of #{describe(holder)}")
        end

        put(name, :waiting, info, since)
        {:waiting, holder}
      end
    end
  end

  # A holder says until when. A lock nobody says it holds is waited for as long as a
  # deployment of this node could hold it
  defp expired?(%{expires_at: expires_at}, _since, _info, now), do: now > expires_at
  defp expired?(nil, since, info, now), do: now > since + hold_ms(info) + @grace_ms

  defp put(name, state, info, since) do
    GenServer.cast(__MODULE__, {:monitor, self()})

    :ets.insert(
      @table,
      {{name, self()},
       %{
         name: name,
         state: state,
         node: Node.self(),
         owner: self(),
         sname: info[:sname],
         from_version: info[:from_version],
         to_version: info[:to_version],
         since: since,
         expires_at: since + hold_ms(info) + @grace_ms
       }}
    )
  end

  defp hold_ms(info), do: info[:hold_ms] || :timer.minutes(10)

  defp holder(name) do
    Enum.find(
      list() ++ peers_list(),
      &(&1.name == name and &1.state == :held and &1.owner != self())
    )
  end

  defp peers_list do
    case Peers.list() do
      [] ->
        []

      peers ->
        peers
        |> :erpc.multicall(__MODULE__, :list, [], @rpc_timeout)
        |> Enum.flat_map(fn
          {:ok, entries} when is_list(entries) -> entries
          _no_answer -> []
        end)
    end
  end

  defp describe(%{node: node, sname: sname, to_version: to_version}),
    do: "#{sname || "a new instance"} to #{to_version} on #{node}"

  defp describe(nil), do: "a DeployEx that does not say it holds it"

  # The entry of the calling process
  defp entry(name) do
    case :ets.lookup(@table, {name, self()}) do
      [{_key, entry}] -> entry
      [] -> nil
    end
  end

  defp table, do: if(:ets.whereis(@table) != :undefined, do: @table)

  defp lock_id(name, owner), do: {{__MODULE__, name}, owner}
end
