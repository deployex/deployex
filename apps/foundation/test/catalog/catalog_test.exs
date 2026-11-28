defmodule Foundation.CatalogTest do
  # NOTE: The setup wipes var_path, a directory the whole suite shares, so this module cannot run
  #       next to the async ones. Removing it while Foundation.CatalogExDocTest walks the same
  #       tree makes its mkdir_p fail with :enotdir
  use ExUnit.Case, async: false

  alias Foundation.Accounts.UserToken
  alias Foundation.Catalog

  setup do
    Application.get_env(:foundation, :var_path) |> File.rm_rf()

    name =
      Application.get_env(:foundation, :applications)
      |> Enum.at(0)
      |> Map.get(:name)

    Catalog.setup_all_apps()
    %{name: name}
  end

  test "setup_all_apps/0 creates the log directory of each application", %{name: name} do
    log_path = Application.get_env(:foundation, :monitored_app_log_path)
    File.rm_rf("#{log_path}/#{name}")
    File.rm_rf("#{log_path}/deployex")

    assert :ok = Catalog.setup_all_apps()

    assert File.dir?("#{log_path}/#{name}")
    refute File.dir?("#{log_path}/deployex")
  end

  test "versions/2", %{name: name} do
    assert Catalog.versions(name, []) == []
  end

  test "add_version/1", %{name: name} do
    version = %Catalog.Version{version: "0.0.0", name: name}
    assert :ok = Catalog.add_version(version)
    assert [^version] = Catalog.versions(name, [])
  end

  describe "relups" do
    defp relup(from_version, to_version) do
      %{
        from_version: from_version,
        to_version: to_version,
        summary: %{modules: 2},
        text: "{\"#{to_version}\",[{\"#{from_version}\",[],[point_of_no_return]}],[]}.\n",
        inserted_at: ~N[2026-11-23 10:00:00]
      }
    end

    test "add_relup/2 keeps the relup of an upgrade, relup/3 reads it back", %{name: name} do
      assert Catalog.relup(name, "1.0.0", "1.1.0") == nil

      assert :ok = Catalog.add_relup(name, relup("1.0.0", "1.1.0"))
      assert :ok = Catalog.add_relup(name, relup("1.1.0", "1.2.0-9cad9cd+build.5"))

      assert Catalog.relup(name, "1.0.0", "1.1.0") == relup("1.0.0", "1.1.0")

      assert %{to_version: "1.2.0-9cad9cd+build.5"} =
               Catalog.relup(name, "1.1.0", "1.2.0-9cad9cd+build.5")

      # The same two versions on another instance are the same upgrade
      assert :ok = Catalog.add_relup(name, %{relup("1.0.0", "1.1.0") | summary: %{modules: 3}})
      assert %{summary: %{modules: 3}} = Catalog.relup(name, "1.0.0", "1.1.0")
    end

    test "a version that is not a plain file name is neither written nor read", %{name: name} do
      for version <- ["../../etc/passwd", "1.0.0/..", "..", "", "1.0 0", "1.1.0\n", nil] do
        assert Catalog.add_relup(name, relup("1.0.0", version)) == {:error, :invalid_relup_name}
        assert Catalog.add_relup(name, relup(version, "1.1.0")) == {:error, :invalid_relup_name}
        assert Catalog.relup(name, "1.0.0", version) == nil
        assert Catalog.relup(name, version, "1.1.0") == nil
      end

      assert Catalog.relup("../#{name}", "1.0.0", "1.1.0") == nil
    end

    test "a kept file that cannot be read back reads as no relup", %{name: name} do
      assert :ok = Catalog.add_relup(name, relup("1.0.0", "1.1.0"))

      path =
        Path.join([
          Application.fetch_env!(:foundation, :var_path),
          "storage",
          name,
          "deployex",
          "relup",
          "1.0.0_to_1.1.0.relup"
        ])

      # What a write that was cut short leaves
      File.write!(path, "not a term")

      assert Catalog.relup(name, "1.0.0", "1.1.0") == nil

      # Nothing but the relups is left in the directory, a write goes through a file of its own
      assert :ok = Catalog.add_relup(name, relup("1.0.0", "1.1.0"))
      assert File.ls!(Path.dirname(path)) == ["1.0.0_to_1.1.0.relup"]
      assert Catalog.relup(name, "1.0.0", "1.1.0") == relup("1.0.0", "1.1.0")
    end

    test "add_relup/2 keeps the newest 20 relups of an application", %{name: name} do
      for patch <- 1..23 do
        assert :ok = Catalog.add_relup(name, relup("1.0.#{patch - 1}", "1.0.#{patch}"))

        # The file times have a resolution of a second, so each relup is given its own
        path =
          Path.join([
            Application.fetch_env!(:foundation, :var_path),
            "storage",
            name,
            "deployex",
            "relup",
            "1.0.#{patch - 1}_to_1.0.#{patch}.relup"
          ])

        File.touch!(path, 1_700_000_000 + patch)
      end

      assert Catalog.relup(name, "1.0.0", "1.0.1") == nil
      assert Catalog.relup(name, "1.0.2", "1.0.3") == nil
      assert %{to_version: "1.0.4"} = Catalog.relup(name, "1.0.3", "1.0.4")
      assert %{to_version: "1.0.23"} = Catalog.relup(name, "1.0.22", "1.0.23")
    end
  end

  test "ghosted_versions/0", %{name: name} do
    assert [] == Catalog.ghosted_versions(name)
  end

  test "add_ghosted_version/1", %{name: name} do
    version = %Catalog.Version{version: "0.0.0", name: name}
    assert {:ok, [^version]} = Catalog.add_ghosted_version(version)
    assert [^version] = Catalog.ghosted_versions(name)
  end

  test "remove_ghosted_version/2", %{name: name} do
    keep = %Catalog.Version{version: "1.0.0", name: name}
    remove = %Catalog.Version{version: "2.0.0", name: name}

    assert {:ok, _} = Catalog.add_ghosted_version(keep)
    assert {:ok, _} = Catalog.add_ghosted_version(remove)

    assert {:ok, [^keep]} = Catalog.remove_ghosted_version(name, "2.0.0")
    assert [^keep] = Catalog.ghosted_versions(name)
  end

  test "remove_ghosted_version/2 with a version that is not ghosted", %{name: name} do
    version = %Catalog.Version{version: "1.0.0", name: name}
    assert {:ok, _} = Catalog.add_ghosted_version(version)

    # removing something that was never ghosted leaves the list as it is
    assert {:ok, [^version]} = Catalog.remove_ghosted_version(name, "9.9.9")
  end

  test "remove_ghosted_version/2 allows the version to be ghosted again", %{name: name} do
    version = %Catalog.Version{version: "1.0.0", name: name}

    assert {:ok, _} = Catalog.add_ghosted_version(version)
    assert {:ok, []} = Catalog.remove_ghosted_version(name, "1.0.0")
    assert {:ok, [^version]} = Catalog.add_ghosted_version(version)
  end

  test "clear_ghosted_versions/1", %{name: name} do
    assert {:ok, _} = Catalog.add_ghosted_version(%Catalog.Version{version: "1.0.0", name: name})
    assert {:ok, _} = Catalog.add_ghosted_version(%Catalog.Version{version: "2.0.0", name: name})

    assert {:ok, []} = Catalog.clear_ghosted_versions(name)
    assert [] == Catalog.ghosted_versions(name)
  end

  test "clear_ghosted_versions/1 with an empty list", %{name: name} do
    assert {:ok, []} = Catalog.clear_ghosted_versions(name)
  end

  test "add_user_session_token/1" do
    user_session = %UserToken{token: "123456789"}
    assert :ok = Catalog.add_user_session_token(user_session)
    assert user_session == Catalog.get_user_session_token_by_token(user_session.token)
  end

  test "delete_user_session_token/1" do
    user_session = %UserToken{token: "987654321"}
    assert :ok = Catalog.add_user_session_token(user_session)
    assert :ok = Catalog.delete_user_session_token(user_session.token)
    refute Catalog.get_user_session_token_by_token(user_session.token)
  end

  test "config/1", %{name: name} do
    assert %Catalog.Config{mode: :automatic, manual_version: nil} = Catalog.config(name)
  end

  test "config_update/1", %{name: name} do
    expected_config = %Catalog.Config{mode: :manual, manual_version: nil}
    config = Catalog.config(name)
    assert {:ok, ^expected_config} = Catalog.config_update(name, %{config | mode: :manual})
    assert ^expected_config = Catalog.config(name)
  end
end
