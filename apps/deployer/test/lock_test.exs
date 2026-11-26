defmodule Deployer.LockTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Deployer.Lock

  @info %{sname: "myapp-abc123", from_version: "1.0.0", to_version: "2.0.0", hold_ms: 1_000}

  # A process that takes the lock and keeps it until it is told to give it back or to stop
  defp holder(name, info \\ @info) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:acquired, Lock.acquire(name, info)})

        receive do
          :release -> send(test, {:released, Lock.release(name)})
          :stop -> :ok
        end
      end)

    assert_receive {:acquired, :ok}
    pid
  end

  defp name, do: "app-#{System.unique_integer([:positive])}"

  test "the process that takes the lock holds it until it gives it back" do
    name = name()

    refute Lock.held?(name)
    assert Lock.acquire(name, @info) == :ok
    assert Lock.held?(name)
    assert Lock.acquire(name, @info) == :ok

    assert [%{name: ^name, state: :held, sname: "myapp-abc123", to_version: "2.0.0"} = entry] =
             Enum.filter(Lock.list(), &(&1.name == name))

    assert entry.node == Node.self()
    assert entry.owner == self()
    assert entry.expires_at == entry.since + 1_000 + :timer.minutes(1)

    assert Lock.release(name) == :ok
    refute Lock.held?(name)
    assert Enum.filter(Lock.list(), &(&1.name == name)) == []
  end

  test "another process waits, and is told who holds it" do
    name = name()
    holder = holder(name)

    log =
      capture_log(fn ->
        assert {:waiting, %{state: :held, owner: ^holder, to_version: "2.0.0"}} =
                 Lock.acquire(name, %{@info | to_version: "2.0.1"})

        # Waiting is said once
        assert {:waiting, _holder} = Lock.acquire(name, @info)
      end)

    assert log |> String.split("waits for the one of") |> length() == 2
    refute Lock.held?(name)

    assert [:held, :waiting] ==
             Lock.fleet() |> Enum.filter(&(&1.name == name)) |> Enum.map(& &1.state)

    send(holder, :release)
    assert_receive {:released, :ok}

    assert Lock.acquire(name, @info) == :ok
    assert Lock.held?(name)
    Lock.release(name)
  end

  test "the lock of one application does not hold another" do
    holder = holder(name())

    other = name()
    assert Lock.acquire(other, @info) == :ok
    Lock.release(other)
    send(holder, :stop)
  end

  test "the lock of a process that is gone is free, and its entry is removed" do
    name = name()
    holder = holder(name)
    ref = Process.monitor(holder)

    send(holder, :stop)
    assert_receive {:DOWN, ^ref, :process, ^holder, _reason}

    # The server that owns the table has seen it too
    :sys.get_state(Lock)
    assert Enum.filter(Lock.list(), &(&1.name == name)) == []

    # :global frees the lock of a process that is gone a moment after it is gone
    assert acquired_within?(name, 1_000)
    Lock.release(name)
  end

  defp acquired_within?(name, ms) do
    cond do
      Lock.acquire(name, @info) == :ok -> true
      ms <= 0 -> false
      true -> Process.sleep(20) && acquired_within?(name, ms - 20)
    end
  end

  test "a lock that was not given back in time is not waited for" do
    name = name()
    # It could be held until a minute ago
    holder = holder(name, %{@info | hold_ms: -:timer.minutes(2)})

    log = capture_log(fn -> assert Lock.acquire(name, @info) == :ok end)

    assert log =~ "was not given back in time"
    assert Lock.held?(name)

    assert [%{state: :forced}] =
             Enum.filter(Lock.list(), &(&1.name == name and &1.owner == self()))

    Lock.release(name)
    send(holder, :stop)
  end

  test "without its table, as after a hot upgrade of DeployEx, nothing is locked" do
    name = name()
    :ok = Supervisor.terminate_child(Deployer.Supervisor, Lock)

    try do
      assert Lock.acquire(name, @info) == :ok
      refute Lock.held?(name)
      assert Lock.release(name) == :ok
      assert Lock.list() == []
      assert Lock.fleet() == []
    after
      {:ok, _pid} = Supervisor.restart_child(Deployer.Supervisor, Lock)
    end
  end

  test "cancel/2 says when the node cannot be asked" do
    assert {:error, _reason} = Lock.cancel(:"deployex@not-a-host", "myapp")
  end
end
