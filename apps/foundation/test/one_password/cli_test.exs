defmodule Foundation.OnePassword.CliTest do
  use ExUnit.Case, async: false

  alias Foundation.OnePassword.Cli

  @path "vaults/production/items/myphoenixapp"

  @output Jason.encode!(%{
            "id" => "2fcbqwe9ndg175zg2dzwftvkpa",
            "title" => "myphoenixapp",
            "fields" => [
              %{
                "id" => "notesPlain",
                "type" => "STRING",
                "purpose" => "NOTES",
                "label" => "notesPlain"
              },
              %{
                "id" => "a",
                "type" => "CONCEALED",
                "label" => "DATABASE_URL",
                "value" => "ecto://db"
              }
            ]
          })

  @env_names ~w(PATH OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST OP_CONNECT_TOKEN OP_TEST_DIR)

  # A stand-in `op` on the PATH: a shell script that writes its arguments and its OS pid to
  # files, then does what `script` says. The environment is the real one, restored afterwards
  setup do
    dir = Path.join(System.tmp_dir!(), "op-cli-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Map.new(@env_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(dir)
    end)

    Enum.each(~w(OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST OP_CONNECT_TOKEN), &System.delete_env/1)
    System.put_env("OP_TEST_DIR", dir)
    System.put_env("PATH", dir <> ":" <> previous["PATH"])

    %{dir: dir}
  end

  defp install_op(dir, script) do
    path = Path.join(dir, "op")

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$@" > "$OP_TEST_DIR/args"
    echo $$ > "$OP_TEST_DIR/pid"
    #{script}
    """)

    File.chmod!(path, 0o755)
  end

  defp print(dir, output) do
    File.write!(Path.join(dir, "output"), output)
    ~s(cat "$OP_TEST_DIR/output")
  end

  defp service_account, do: System.put_env("OP_SERVICE_ACCOUNT_TOKEN", "ops_token")

  test "fetch/1 asks op for the item as JSON, with its vault and its concealed values", %{
    dir: dir
  } do
    install_op(dir, print(dir, @output))
    service_account()

    assert Cli.fetch(@path) == {:ok, %{"DATABASE_URL" => "ecto://db"}}

    assert dir |> Path.join("args") |> File.read!() |> String.split("\n", trim: true) ==
             [
               "item",
               "get",
               "myphoenixapp",
               "--vault",
               "production",
               "--format",
               "json",
               "--reveal"
             ]
  end

  test "fetch/1 also runs when op is pointed at a Connect server", %{dir: dir} do
    install_op(dir, print(dir, ~s({"id":"x"})))
    System.put_env("OP_CONNECT_HOST", "http://connect:8080")
    System.put_env("OP_CONNECT_TOKEN", "connect-token")

    assert Cli.fetch(@path) == {:ok, %{}}
  end

  test "fetch/1 reports the exit status of a failed command, not its output", %{dir: dir} do
    install_op(dir, print(dir, "partial output that could hold a value") <> "\nexit 1")
    service_account()

    assert Cli.fetch(@path) == {:error, {:op_exit_status, 1}}
  end

  test "fetch/1 reports output that is not JSON", %{dir: dir} do
    install_op(dir, print(dir, "not json"))
    service_account()

    assert Cli.fetch(@path) == {:error, :invalid_json}
  end

  test "fetch/1 says when op is not installed", %{dir: dir} do
    # Only the directory of the test, which has no op in it
    System.put_env("PATH", dir)
    service_account()

    assert Cli.fetch(@path) == {:error, :op_not_found}
  end

  test "fetch/1 kills an op that does not answer in time", %{dir: dir} do
    install_op(dir, "exec sleep 30")
    service_account()

    assert Cli.fetch(@path, timeout_ms: 300) == {:error, {:op_timeout, 300}}

    os_pid = dir |> Path.join("pid") |> File.read!() |> String.trim()

    # kill -0 only asks whether the process is there. It is reaped a moment after the kill
    gone? =
      Enum.any?(1..20, fn _attempt ->
        Process.sleep(50)

        match?(
          {_output, status} when status != 0,
          System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
        )
      end)

    assert gone?

    # Nothing of the port is left in the mailbox of the caller
    {:messages, messages} = Process.info(self(), :messages)
    refute Enum.any?(messages, &match?({port, _message} when is_port(port), &1))
  end

  test "fetch/1 does not run op without credentials, or with a bad path", %{dir: dir} do
    install_op(dir, print(dir, @output))

    for env <- [
          %{},
          %{"OP_SERVICE_ACCOUNT_TOKEN" => ""},
          %{"OP_CONNECT_HOST" => "http://connect:8080"}
        ] do
      Enum.each(env, fn {name, value} -> System.put_env(name, value) end)

      assert Cli.fetch(@path) == {:error, {:missing_env, ["OP_SERVICE_ACCOUNT_TOKEN"]}}

      Enum.each(env, fn {name, _value} -> System.delete_env(name) end)
    end

    service_account()

    assert Cli.fetch("myphoenixapp") == {:error, :invalid_path}

    refute File.exists?(Path.join(dir, "args"))
  end
end
