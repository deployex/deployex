defmodule Foundation.ConfigProvider.Secrets.OnePasswordTest do
  use ExUnit.Case, async: false

  import Mock

  alias Foundation.ConfigProvider.Secrets.Manager
  alias Foundation.ConfigProvider.Secrets.OnePasswordCli
  alias Foundation.ConfigProvider.Secrets.OnePasswordConnect
  alias Foundation.OnePassword

  @path "vaults/production/items/deployex"

  @fields %{
    "DEPLOYEX_ADMIN_HASHED_PASSWORD" =>
      "$2b$12$nqB622nfq7KOWYS97xDrP.8DNToPxf4zHZFXeVOPc7GnlJbZ7.Dyq",
    "DEPLOYEX_ERLANG_COOKIE" => "cookie",
    "DEPLOYEX_SECRET_KEY_BASE" =>
      "RsE6okQAKEfugxTRy5AGrQSZxnywA95AR/PRKGQNoemjg7w+Zgb8wp+UexIkgwsM"
  }

  for {adapter, client} <- [
        {OnePasswordConnect, OnePassword.Connect},
        {OnePasswordCli, OnePassword.Cli}
      ] do
    describe "#{inspect(adapter)}" do
      @tag :capture_log
      test "secrets/3 gives DeployEx its own secrets, the fields of the item" do
        with_mock unquote(client), fetch: fn @path -> {:ok, @fields} end do
          assert [
                   {:foundation,
                    [
                      {Manager, [adapter: unquote(adapter), path: @path]},
                      {Foundation.Accounts,
                       [
                         admin_hashed_password:
                           "$2b$12$nqB622nfq7KOWYS97xDrP.8DNToPxf4zHZFXeVOPc7GnlJbZ7.Dyq"
                       ]}
                    ]},
                   {:deployex_web,
                    [
                      {DeployexWeb.Endpoint,
                       [
                         secret_key_base:
                           "RsE6okQAKEfugxTRy5AGrQSZxnywA95AR/PRKGQNoemjg7w+Zgb8wp+UexIkgwsM"
                       ]}
                    ]}
                 ] =
                   Manager.load(
                     [foundation: [{Manager, adapter: unquote(adapter), path: @path}]],
                     []
                   )
        end
      end

      test "secrets/3 raises when the item cannot be read, so DeployEx does not start without them" do
        with_mock unquote(client),
          fetch: fn @path -> {:error, {:not_found, :item, "deployex"}} end do
          assert_raise RuntimeError,
                       ~s(Fail to retrieve secrets with reason {:not_found, :item, "deployex"}),
                       fn -> unquote(adapter).secrets([], @path, []) end
        end
      end

      test "application_env/1 gives a monitored application its environment, sorted by name" do
        fields = %{"SECRET_KEY_BASE" => "abc", "DATABASE_URL" => "ecto://db"}

        with_mock unquote(client), fetch: fn @path -> {:ok, fields} end do
          assert unquote(adapter).application_env(@path) ==
                   {:ok, [{"DATABASE_URL", "ecto://db"}, {"SECRET_KEY_BASE", "abc"}]}
        end
      end

      test "application_env/1 returns the error of an item that cannot be read" do
        with_mock unquote(client),
          fetch: fn @path -> {:error, {:http_status, 401, "/v1/vaults"}} end do
          assert unquote(adapter).application_env(@path) ==
                   {:error, {:http_status, 401, "/v1/vaults"}}
        end
      end
    end
  end
end
