defmodule Sentinel.Logs.ServerTest do
  use ExUnit.Case, async: false

  import Mock
  import Mox

  alias Foundation.Catalog
  alias Host.Terminal
  alias Sentinel.Logs.Message
  alias Sentinel.Logs.Output
  alias Sentinel.Logs.Server

  setup [
    :set_mox_from_context,
    :verify_on_exit!,
    :create_consumer
  ]

  test "[un]subscribe_for_new_logs/0", %{sname: sname, pid: pid} do
    log_type = "new-log-type"
    message = "[info] simple log"
    Server.subscribe_for_new_logs(sname, log_type)

    send(
      pid,
      {:terminal_update,
       %{
         metadata: %{context: :terminal_logs, sname: sname, type: log_type},
         source_pid: self(),
         message: message
       }}
    )

    assert_receive {:logs_new_data, ^sname, ^log_type, %Message{timestamp: _, log: ^message}},
                   1_000

    # Validate by inspection
    Server.unsubscribe_for_new_logs(sname, log_type)
  end

  describe "monitored_app_log_stdout" do
    setup do
      # The output is written by its own server. What it writes is kept here
      {:ok, output} = StringIO.open("")
      output_pid = start_supervised!(Output.Server)
      Process.group_leader(output_pid, output)

      on_exit(fn -> Application.delete_env(:foundation, :monitored_app_log_stdout) end)

      {:ok, output: output, output_pid: output_pid}
    end

    defp send_log(context, log_type, message) do
      %{pid: pid, sname: sname} = context
      Server.subscribe_for_new_logs(sname, log_type)

      send(
        pid,
        {:terminal_update,
         %{
           metadata: %{context: :terminal_logs, sname: sname, type: log_type},
           source_pid: self(),
           message: message
         }}
      )

      # The dashboard gets it whatever the option says
      assert_receive {:logs_new_data, ^sname, ^log_type, %Message{log: ^message}}, 1_000

      # Both servers are done with it
      :sys.get_state(pid)
      :sys.get_state(context.output_pid)
    end

    test "hands what the application wrote to the server of the output", context do
      Application.put_env(:foundation, :monitored_app_log_stdout, true)
      message = ~s({"message":"one"}\n{"message":"two µs 🔥"}\n)

      send_log(context, "stdout", message)

      assert {"", ^message} = StringIO.contents(context.output)
    end

    test "writes nothing to the output when it is off", context do
      send_log(context, "stdout", "[info] simple log\n")

      assert {"", ""} = StringIO.contents(context.output)
    end

    test "keeps the logs of the dashboard when the server of the output is not running",
         context do
      Application.put_env(:foundation, :monitored_app_log_stdout, true)
      stop_supervised!(Output.Server)

      %{pid: pid, sname: sname} = context
      Server.subscribe_for_new_logs(sname, "stdout")

      send(
        pid,
        {:terminal_update,
         %{
           metadata: %{context: :terminal_logs, sname: sname, type: "stdout"},
           source_pid: self(),
           message: "[info] simple log\n"
         }}
      )

      assert_receive {:logs_new_data, ^sname, "stdout", %Message{}}, 1_000
      assert Process.alive?(pid)
    end
  end

  test "get_types_by_sname/1 valid sname", %{sname: sname, pid: pid} do
    log_type = "new-log-type"
    message = "[info] simple log"
    Server.subscribe_for_new_logs(sname, log_type)

    send(
      pid,
      {:terminal_update,
       %{
         metadata: %{context: :terminal_logs, sname: sname, type: log_type},
         source_pid: self(),
         message: message
       }}
    )

    assert_receive {:logs_new_data, ^sname, ^log_type, %Message{timestamp: _, log: _message}},
                   1_000

    log_types = Server.get_types_by_sname(sname)
    assert log_type in log_types
  end

  test "get_types_by_sname/1 invalid sname" do
    assert [] == Server.get_types_by_sname(nil)
  end

  test "list_data_by_sname_log_type/3 has no lines for an sname with no table" do
    assert Server.list_data_by_sname_log_type(
             "never-tailed-#{System.unique_integer([:positive])}",
             "stdout"
           ) == []
  end

  test "list_active_snames/0", %{sname: sname} do
    snames = Server.list_active_snames()
    assert sname in snames
  end

  test "list_data_by_sname_key/3", %{sname: sname, pid: pid} do
    log_type = "new-log-type"
    Server.subscribe_for_new_logs(sname, log_type)

    Enum.each(1..5, fn index ->
      send(
        pid,
        {:terminal_update,
         %{
           metadata: %{context: :terminal_logs, sname: sname, type: log_type},
           source_pid: self(),
           message: "[info] log #{index}"
         }}
      )
    end)

    assert_receive {:logs_new_data, ^sname, ^log_type,
                    %Message{timestamp: _, log: "[info] log 5"}},
                   1_000

    assert [
             %Message{timestamp: _, log: "[info] log 1"},
             %Message{timestamp: _, log: "[info] log 2"},
             %Message{timestamp: _, log: "[info] log 3"},
             %Message{timestamp: _, log: "[info] log 4"},
             %Message{timestamp: _, log: "[info] log 5"}
           ] = Server.list_data_by_sname_log_type(sname, log_type, order: :asc)

    assert [
             %Message{timestamp: _, log: "[info] log 5"},
             %Message{timestamp: _, log: "[info] log 4"},
             %Message{timestamp: _, log: "[info] log 3"},
             %Message{timestamp: _, log: "[info] log 2"},
             %Message{timestamp: _, log: "[info] log 1"}
           ] = Server.list_data_by_sname_log_type(sname, log_type, order: :desc)

    assert [
             %Message{timestamp: _, log: "[info] log 1"},
             %Message{timestamp: _, log: "[info] log 2"},
             %Message{timestamp: _, log: "[info] log 3"},
             %Message{timestamp: _, log: "[info] log 4"},
             %Message{timestamp: _, log: "[info] log 5"}
           ] = Server.list_data_by_sname_log_type(sname, log_type)
  end

  test "list_data_by_sname_log_type/3 keeps the newest messages up to a limit, or a time range",
       %{
         sname: sname,
         pid: pid
       } do
    log_type = "new-log-type"
    Server.subscribe_for_new_logs(sname, log_type)
    now = System.os_time(:millisecond)

    # Two messages three minutes ago, then three now
    for {index, at} <- [{1, now - 180_000}, {2, now - 180_000}, {3, now}, {4, now}, {5, now}] do
      with_mock System, os_time: fn _ -> at end do
        send(
          pid,
          {:terminal_update,
           %{
             metadata: %{context: :terminal_logs, sname: sname, type: log_type},
             source_pid: self(),
             message: "[info] log #{index}"
           }}
        )

        assert_receive {:logs_new_data, ^sname, ^log_type, %Message{}}, 1_000
      end
    end

    assert [%Message{log: "[info] log 2"}, %Message{log: "[info] log 3"} | _] =
             Server.list_data_by_sname_log_type(sname, log_type, limit: 4)

    assert [%Message{log: "[info] log 5"}, %Message{log: "[info] log 4"}] =
             Server.list_data_by_sname_log_type(sname, log_type, limit: 2, order: :desc)

    assert [%Message{log: "[info] log 1"}, %Message{log: "[info] log 2"}] =
             Server.list_data_by_sname_log_type(sname, log_type,
               between: {now - 180_000, now - 179_999}
             )

    assert [%Message{log: "[info] log 3"}, _, %Message{log: "[info] log 5"}] =
             Server.list_data_by_sname_log_type(sname, log_type, between: {now - 1, now + 1})

    assert [] = Server.list_data_by_sname_log_type(sname, log_type, between: {now + 1, now + 1})
  end

  test "Pruning expiring entries", %{sname: sname, pid: pid} do
    log_type = "new-log-type"
    Server.subscribe_for_new_logs(sname, log_type)

    now = System.os_time(:millisecond)

    with_mock System, os_time: fn _ -> now - 120_000 end do
      Enum.each(1..5, fn index ->
        send(
          pid,
          {:terminal_update,
           %{
             metadata: %{context: :terminal_logs, sname: sname, type: log_type},
             source_pid: self(),
             message: "[info] log #{index}"
           }}
        )
      end)

      assert_receive {:logs_new_data, ^sname, ^log_type,
                      %Message{timestamp: _, log: "[info] log 5"}},
                     1_000
    end

    assert [
             %Message{timestamp: _, log: "[info] log 1"},
             %Message{timestamp: _, log: "[info] log 2"},
             %Message{timestamp: _, log: "[info] log 3"},
             %Message{timestamp: _, log: "[info] log 4"},
             %Message{timestamp: _, log: "[info] log 5"}
           ] = Server.list_data_by_sname_log_type(sname, log_type)

    send(pid, :prune_expired_entries)
    :timer.sleep(100)

    assert [] = Server.list_data_by_sname_log_type(sname, log_type, order: :asc)
  end

  test "Pruning expiring entries when retention period is updated", %{sname: sname, pid: pid} do
    log_type = "new-log-type"
    Server.subscribe_for_new_logs(sname, log_type)

    now = System.os_time(:millisecond)

    with_mock System, os_time: fn _ -> now - 30_000 end do
      Enum.each(1..5, fn index ->
        send(
          pid,
          {:terminal_update,
           %{
             metadata: %{context: :terminal_logs, sname: sname, type: log_type},
             source_pid: self(),
             message: "[info] log #{index}"
           }}
        )
      end)

      assert_receive {:logs_new_data, ^sname, ^log_type,
                      %Message{timestamp: _, log: "[info] log 5"}},
                     1_000
    end

    assert [
             %Message{timestamp: _, log: "[info] log 1"},
             %Message{timestamp: _, log: "[info] log 2"},
             %Message{timestamp: _, log: "[info] log 3"},
             %Message{timestamp: _, log: "[info] log 4"},
             %Message{timestamp: _, log: "[info] log 5"}
           ] = Server.list_data_by_sname_log_type(sname, log_type)

    # Update retention period
    Server.update_data_retention_period(1_000)

    :timer.sleep(100)

    assert [] = Server.list_data_by_sname_log_type(sname, log_type, order: :asc)
  end

  test "Check Node up with expected node", %{sname: sname, node: node, pid: pid} do
    log_type = "new-log-type"
    message = "message"
    Server.subscribe_for_new_logs(sname, log_type)

    send(pid, {:nodeup, node})

    send(
      pid,
      {:terminal_update,
       %{
         metadata: %{context: :terminal_logs, sname: sname, type: log_type},
         source_pid: self(),
         message: message
       }}
    )

    assert_receive {:logs_new_data, ^sname, ^log_type, %Message{timestamp: _, log: ^message}},
                   1_000
  end

  test "Check Node down with expected node", %{sname: sname, node: node, pid: pid} do
    log_type = "stderr"
    message = "DeployEx detected node down for node: #{node}"
    Server.subscribe_for_new_logs(sname, log_type)

    send(pid, {:nodedown, node})

    assert_receive {:logs_new_data, ^sname, ^log_type, %Message{timestamp: _, log: ^message}},
                   1_000
  end

  test "Check Node down with unexpected node", %{sname: sname, pid: pid} do
    log_type = "stderr"
    node = :"non-valid-node@nohost"
    message = "DeployEx detected node down for node: #{node}"
    Server.subscribe_for_new_logs(sname, log_type)

    send(pid, {:nodedown, :"nonvalid-node@nohost"})

    refute_receive {:logs_new_data, ^sname, _log_type, %Message{timestamp: _, log: ^message}},
                   1_000
  end

  test "Check Node down of a node of another host", %{sname: sname, pid: pid} do
    log_type = "stderr"
    Server.subscribe_for_new_logs(sname, log_type)

    # The name of a node of this DeployEx, on the host of a connected one
    send(pid, {:nodedown, :"#{sname}@another-host"})
    {:ok, host} = :inet.gethostname()
    send(pid, {:nodedown, :"deployex@#{host}-1"})

    refute_receive {:logs_new_data, _sname, _log_type, %Message{}}, 500
    assert Process.alive?(pid)
  end

  test "Log terminals always capture the tail output from stdout", %{pid: pid} do
    test_pid = self()
    new_sname = Catalog.create_sname("myelixir")
    Catalog.setup_new_node(new_sname)

    # NOTE: tail writes the content of the followed file to its own stdout,
    #       so both the stdout and the stderr log terminals must capture :stdout
    with_mock Terminal,
      new: fn %Terminal{options: options, metadata: %{type: type}} ->
        send(test_pid, {:terminal_created, type, options})
        :ok
      end do
      send(pid, {:new_deploy, Node.self(), new_sname})

      assert_receive {:terminal_created, "stdout", [:stdout]}, 1_000
      assert_receive {:terminal_created, "stderr", [:stdout]}, 1_000
    end
  end

  test "Check no Terminal is created if there is no log file", %{
    fake_sname: fake_sname,
    sname: sname,
    pid: pid
  } do
    log_type = "new-log-type"
    message = "[info] simple log"
    Server.subscribe_for_new_logs(sname, log_type)
    Server.subscribe_for_new_logs(fake_sname, log_type)

    send(
      pid,
      {:terminal_update,
       %{
         metadata: %{context: :terminal_logs, sname: fake_sname, type: log_type},
         source_pid: self(),
         message: message
       }}
    )

    # Send a valid date just to guarantee the previous message was processed
    send(
      pid,
      {:terminal_update,
       %{
         metadata: %{context: :terminal_logs, sname: sname, type: log_type},
         source_pid: self(),
         message: message
       }}
    )

    assert_receive {:logs_new_data, ^sname, ^log_type, %Message{timestamp: _, log: _message}},
                   1_000

    assert [] == Server.get_types_by_sname(fake_sname)
  end

  defp create_consumer(context) do
    sname = Catalog.create_sname("myelixir")
    %{node: node} = Catalog.node_info(sname)
    Catalog.setup_new_node(sname)

    node_self = Node.self()
    Catalog.setup_new_node("nonode")

    fake_sname = Catalog.create_sname("fake")

    Host.CommanderMock
    |> stub(:run, fn _command, _options -> {:ok, self(), "123456"} end)
    |> stub(:stop, fn _pid -> :ok end)

    Deployer.MonitorMock
    |> expect(:list, fn -> [sname] end)
    |> expect(:subscribe_new_deploy, fn -> :ok end)

    test_pid = self()

    with_mock Terminal, new: fn %Terminal{} -> :ok end do
      {:ok, pid} = Server.start_link(data_retention_period: :timer.minutes(1))
      send(test_pid, {:server_pid, pid})
      send(pid, {:new_deploy, node_self, sname})
      send(pid, {:new_deploy, node_self, fake_sname})
    end

    assert_receive {:server_pid, pid}, 1_000

    context
    |> Map.put(:fake_sname, fake_sname)
    |> Map.put(:sname, sname)
    |> Map.put(:node, node)
    |> Map.put(:pid, pid)
  end

  test "starts the pruning timer when retention is enabled after init", %{pid: existing_pid} do
    # Stop the server from the shared setup so we can start our own with nil retention
    GenServer.stop(existing_pid)

    sname = Catalog.create_sname("myelixir")
    Catalog.setup_new_node(sname)

    Host.CommanderMock
    |> stub(:run, fn _command, _options -> {:ok, self(), "123456"} end)
    |> stub(:stop, fn _pid -> :ok end)

    Deployer.MonitorMock
    |> stub(:list, fn -> [sname] end)
    |> stub(:subscribe_new_deploy, fn -> :ok end)

    # Start with retention disabled (nil)
    {:ok, pid} =
      with_mock Host.Terminal, new: fn %Host.Terminal{} -> :ok end do
        Server.start_link(data_retention_period: nil)
      end

    # Sanity: no timer ref in state
    assert %{prune_timer_ref: nil} = :sys.get_state(pid)

    # Enable retention: the timer should start
    Server.update_data_retention_period(:timer.minutes(1))
    :timer.sleep(50)

    assert %{prune_timer_ref: ref} = :sys.get_state(pid)
    assert ref != nil

    # Disable retention: the timer should be cancelled
    Server.update_data_retention_period(nil)
    :timer.sleep(50)

    assert %{prune_timer_ref: nil} = :sys.get_state(pid)

    GenServer.stop(pid)
  end
end
