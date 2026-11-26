defmodule Sentinel.Logs.Output.ServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Sentinel.Logs.Output.Server

  @sname "myelixir-1"

  setup context do
    Application.put_env(:foundation, :monitored_app_log_stdout, true)
    on_exit(fn -> Application.delete_env(:foundation, :monitored_app_log_stdout) end)

    # What the server writes to its output, kept here
    {:ok, output} = StringIO.open("")
    flush_interval = Map.get(context, :flush_interval, :timer.minutes(1))
    pid = start_supervised!({Server, name: context.test, flush_interval: flush_interval})
    Process.group_leader(pid, output)

    {:ok, pid: pid, output: output}
  end

  defp forward(pid, log_key, message, sname \\ @sname) do
    assert :ok = Server.forward(sname, log_key, message, pid)
    # The cast was handled
    :sys.get_state(pid)
  end

  defp written(output), do: output |> StringIO.contents() |> elem(1)

  test "writes whole lines as they are", %{pid: pid, output: output} do
    message = ~s({"message":"one"}\n{"message":"two"}\n)

    forward(pid, "stdout", message)

    assert written(output) == message
  end

  test "keeps the end of a line until the rest of it comes", %{pid: pid, output: output} do
    forward(pid, "stdout", ~s({"message":"one"}\n{"mess))
    assert written(output) == ~s({"message":"one"}\n)

    forward(pid, "stdout", ~s(age":"two"}\n))
    assert written(output) == ~s({"message":"one"}\n{"message":"two"}\n)
  end

  test "keeps a character that was cut between two pieces", %{pid: pid, output: output} do
    <<first::binary-size(23), second::binary>> = "[info] Sent 200 in 300µs 🔥\n"
    refute String.valid?(first)

    forward(pid, "stdout", first)
    forward(pid, "stdout", second)

    assert written(output) == "[info] Sent 200 in 300µs 🔥\n"
  end

  test "does not mix the lines of two applications", %{pid: pid, output: output} do
    forward(pid, "stdout", "one of ", "myelixir-1")
    forward(pid, "stdout", "two of ", "myelixir-2")
    forward(pid, "stdout", "the first\n", "myelixir-1")
    forward(pid, "stdout", "the second\n", "myelixir-2")

    assert written(output) == "one of the first\ntwo of the second\n"
  end

  test "replaces the bytes that are not UTF-8", %{pid: pid, output: output} do
    forward(pid, "stdout", <<"bad ", 0xFF, " byte\n">>)

    assert written(output) == "bad � byte\n"
  end

  @tag flush_interval: 10
  test "writes a line that has no end after the flush interval", %{pid: pid, output: output} do
    forward(pid, "stdout", "no line break")
    assert written(output) == ""

    Process.sleep(50)
    assert %Server{buffers: buffers, flush_timer_ref: nil} = :sys.get_state(pid)
    assert buffers == %{}
    assert written(output) == "no line break"
  end

  @tag flush_interval: 10
  test "a flush keeps the bytes of a character that is not whole", %{pid: pid, output: output} do
    <<first::binary-size(23), second::binary>> = "[info] Sent 200 in 300µs\n"

    forward(pid, "stdout", first)
    Process.sleep(50)
    assert written(output) == "[info] Sent 200 in 300"

    forward(pid, "stdout", second)
    assert written(output) == "[info] Sent 200 in 300µs\n"
  end

  test "writes stderr to the standard error", %{pid: pid, output: output} do
    captured =
      capture_io(:stderr, fn ->
        forward(pid, "stderr", "[error] failed\n")
      end)

    assert captured == "[error] failed\n"
    assert written(output) == ""
  end

  test "a closed output does not stop the server", %{pid: pid, output: output} do
    StringIO.close(output)

    forward(pid, "stdout", "[info] simple log\n")

    assert Process.alive?(pid)
  end

  test "does nothing when the option is off", %{pid: pid, output: output} do
    Application.put_env(:foundation, :monitored_app_log_stdout, false)

    forward(pid, "stdout", "[info] simple log\n")

    assert written(output) == ""
  end

  test "does nothing for what is not a binary or when the server is not running" do
    assert :ok = Server.forward(@sname, "stdout", nil)
    assert :ok = Server.forward(@sname, "stdout", "[info] simple log\n", :not_running)
  end

  test "drops the pieces when too many are waiting", %{pid: pid, output: output} do
    :sys.suspend(pid)
    Enum.each(1..5_010, fn _n -> Server.forward(@sname, "stdout", "a\n", pid) end)
    :sys.resume(pid)
    :sys.get_state(pid)

    assert byte_size(written(output)) == 5_000 * 2
  end
end
