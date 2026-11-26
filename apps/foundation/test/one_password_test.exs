defmodule Foundation.OnePasswordTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Foundation.OnePassword

  doctest Foundation.OnePassword

  test "path_error/1 names the path and the expected format" do
    assert OnePassword.path_error("production/app") ==
             ~s(1Password path "production/app" not supported, expected vaults/<vault>/items/<item>)
  end

  test "fields_to_map/1 returns nothing for an item without a list of fields" do
    assert OnePassword.fields_to_map(nil) == %{}
  end

  test "to_env/1 leaves out the labels that cannot be environment variables, and names them" do
    fields = %{
      "DATABASE_URL" => "ecto://db",
      "recovery key" => "top-secret-recovery",
      "1ST" => "top-secret-digit",
      "RELEASE_COOKIE" => "top-secret-cookie",
      "DEPLOYEX_SECRET_KEY_BASE" => "top-secret-key-base"
    }

    log =
      capture_log(fn ->
        assert OnePassword.to_env(fields) == [{"DATABASE_URL", "ecto://db"}]
      end)

    for label <- ["recovery key", "1ST", "RELEASE_COOKIE", "DEPLOYEX_SECRET_KEY_BASE"] do
      assert log =~ label
    end

    # The values are never logged
    refute log =~ "top-secret"
  end

  test "to_env/1 logs nothing when every label is usable" do
    assert capture_log(fn -> OnePassword.to_env(%{"A" => "1"}) end) == ""
  end
end
