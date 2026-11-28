defmodule Foundation.ConfigProvider.Secrets.DirectoryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Foundation.ConfigProvider.Secrets.Directory

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "deployex-directory-secrets-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp write(dir, name, content), do: File.write!(Path.join(dir, name), content)

  describe "secrets/3" do
    test "reads every file in the directory into a map", %{dir: dir} do
      write(dir, "DEPLOYEX_SECRET_KEY_BASE", "abc123\n")
      write(dir, "DEPLOYEX_ERLANG_COOKIE", "cookie")

      assert Directory.secrets([], dir, []) == %{
               "DEPLOYEX_SECRET_KEY_BASE" => "abc123",
               "DEPLOYEX_ERLANG_COOKIE" => "cookie"
             }
    end

    test "removes one trailing newline, not every one", %{dir: dir} do
      write(dir, "ONE", "abc\n")
      write(dir, "CRLF", "abc\r\n")
      write(dir, "TWO", "abc\n\n")
      write(dir, "NONE", "abc")

      secrets = Directory.secrets([], dir, [])

      assert secrets["ONE"] == "abc"
      assert secrets["CRLF"] == "abc"
      assert secrets["TWO"] == "abc\n"
      assert secrets["NONE"] == "abc"
    end

    test "skips names that start with a dot, as a Kubernetes Secret volume's own ..data needs",
         %{dir: dir} do
      write(dir, "DATABASE_URL", "ecto://db")
      write(dir, "..data", "not a secret")
      write(dir, ".hidden", "not a secret")

      assert Directory.secrets([], dir, []) == %{"DATABASE_URL" => "ecto://db"}
    end

    test "raises when the directory cannot be read" do
      assert_raise RuntimeError,
                   ~s(Fail to retrieve secrets with reason :enoent),
                   fn -> Directory.secrets([], "/no/such/directory", []) end
    end

    test "raises when an entry cannot be read as a file, instead of a File.Error", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "SUBDIR"))

      assert_raise RuntimeError,
                   ~s(Fail to retrieve secrets with reason :eisdir),
                   fn -> Directory.secrets([], dir, []) end
    end
  end

  describe "application_env/1" do
    test "returns the files of the directory, sorted by name", %{dir: dir} do
      write(dir, "SECRET_KEY_BASE", "abc")
      write(dir, "DATABASE_URL", "ecto://db\n")

      assert Directory.application_env(dir) ==
               {:ok, [{"DATABASE_URL", "ecto://db"}, {"SECRET_KEY_BASE", "abc"}]}
    end

    test "leaves out a name that is not a valid environment variable, and logs it", %{dir: dir} do
      write(dir, "DATABASE_URL", "ecto://db")
      write(dir, "not-a-valid-name", "x")

      log =
        capture_log(fn ->
          assert Directory.application_env(dir) == {:ok, [{"DATABASE_URL", "ecto://db"}]}
        end)

      assert log =~ "not-a-valid-name"
    end

    test "leaves out RELEASE_ and DEPLOYEX_ names, which DeployEx itself removes", %{dir: dir} do
      write(dir, "DATABASE_URL", "ecto://db")
      write(dir, "RELEASE_COOKIE", "x")
      write(dir, "DEPLOYEX_SECRET_KEY_BASE", "y")

      assert Directory.application_env(dir) == {:ok, [{"DATABASE_URL", "ecto://db"}]}
    end

    test "returns the error of a directory that cannot be read" do
      assert Directory.application_env("/no/such/directory") == {:error, :enoent}
    end

    test "returns the error of an entry that cannot be read as a file, instead of raising", %{
      dir: dir
    } do
      File.mkdir_p!(Path.join(dir, "SUBDIR"))

      assert Directory.application_env(dir) == {:error, :eisdir}
    end
  end
end
