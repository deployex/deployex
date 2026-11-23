defmodule Foundation.OnePassword.CliTest do
  use ExUnit.Case, async: false

  import Mock

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

  defp with_op(env, cmd, fun) do
    with_mock System, [:passthrough], get_env: fn name -> env[name] end, cmd: cmd do
      fun.()
    end
  end

  defp service_account, do: %{"OP_SERVICE_ACCOUNT_TOKEN" => "ops_token"}

  test "fetch/1 asks op for the item as JSON, with its vault and its concealed values" do
    test_pid = self()

    cmd = fn "op", args ->
      send(test_pid, {:op, args})
      {@output, 0}
    end

    with_op(service_account(), cmd, fn ->
      assert Cli.fetch(@path) == {:ok, %{"DATABASE_URL" => "ecto://db"}}
    end)

    assert_received {:op,
                     [
                       "item",
                       "get",
                       "myphoenixapp",
                       "--vault",
                       "production",
                       "--format",
                       "json",
                       "--reveal"
                     ]}
  end

  test "fetch/1 also runs when op is pointed at a Connect server" do
    env = %{"OP_CONNECT_HOST" => "http://connect:8080", "OP_CONNECT_TOKEN" => "connect-token"}

    with_op(env, fn "op", _args -> {~s({"id":"x"}), 0} end, fn ->
      assert Cli.fetch(@path) == {:ok, %{}}
    end)
  end

  test "fetch/1 reports the exit status of a failed command, not its output" do
    cmd = fn "op", _args -> {"partial output that could hold a value", 1} end

    with_op(service_account(), cmd, fn ->
      assert Cli.fetch(@path) == {:error, {:op_exit_status, 1}}
    end)
  end

  test "fetch/1 reports output that is not JSON" do
    with_op(service_account(), fn "op", _args -> {"not json", 0} end, fn ->
      assert Cli.fetch(@path) == {:error, :invalid_json}
    end)
  end

  test "fetch/1 says when op is not installed, and lets any other failure through" do
    not_found = fn "op", _args -> raise ErlangError, original: :enoent end

    with_op(service_account(), not_found, fn ->
      assert Cli.fetch(@path) == {:error, :op_not_found}
    end)

    no_access = fn "op", _args -> raise ErlangError, original: :eacces end

    with_op(service_account(), no_access, fn ->
      assert_raise ErlangError, fn -> Cli.fetch(@path) end
    end)
  end

  test "fetch/1 does not run op without credentials, or with a bad path" do
    never = fn "op", _args -> flunk("op must not run") end

    for env <- [
          %{},
          %{"OP_SERVICE_ACCOUNT_TOKEN" => ""},
          %{"OP_CONNECT_HOST" => "http://connect:8080"}
        ] do
      with_op(env, never, fn ->
        assert Cli.fetch(@path) == {:error, {:missing_env, ["OP_SERVICE_ACCOUNT_TOKEN"]}}
      end)
    end

    with_op(service_account(), never, fn ->
      assert Cli.fetch("myphoenixapp") == {:error, :invalid_path}
    end)
  end
end
