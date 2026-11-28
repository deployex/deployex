defmodule Host.Info.DescriptionTest do
  use ExUnit.Case, async: false

  import Mox

  alias Host.Info.Description

  setup :set_mox_global
  setup :verify_on_exit!

  @os_release "cat /etc/os-release | grep VERSION= | sed 's/VERSION=//; s/\"//g'"

  defp stub_linux(
         container_result,
         os_release_result \\ {:ok, [{:stdout, ["24.04.1 LTS (Noble Numbat)"]}]}
       ) do
    stub(Host.CommanderMock, :run, fn
      "if grep -qa kubepods" <> _, [:stdout, :sync] -> container_result
      @os_release, [:stdout, :sync] -> os_release_result
    end)
  end

  test "Linux outside a container reports no container runtime" do
    stub_linux({:ok, [{:stdout, ["none"]}]})
    assert %Description{host: "Linux", container: nil} = Description.get_linux()
  end

  test "Linux inside Docker reports the docker runtime" do
    stub_linux({:ok, [{:stdout, ["docker"]}]})
    assert %Description{host: "Linux", container: "docker"} = Description.get_linux()
  end

  test "Linux inside a Kubernetes pod reports the kubernetes runtime" do
    stub_linux({:ok, [{:stdout, ["kubernetes"]}]})
    assert %Description{host: "Linux", container: "kubernetes"} = Description.get_linux()
  end

  test "the kubepods cgroup is checked before /.dockerenv, so a dockershim pod is Kubernetes" do
    stub(Host.CommanderMock, :run, fn
      "if grep -qa kubepods" <> _ = command, [:stdout, :sync] ->
        {kubepods_at, _} = :binary.match(command, "kubepods")
        {dockerenv_at, _} = :binary.match(command, "/.dockerenv")
        assert kubepods_at < dockerenv_at
        {:ok, [{:stdout, ["kubernetes"]}]}

      @os_release, [:stdout, :sync] ->
        {:ok, [{:stdout, ["24.04.1 LTS (Noble Numbat)"]}]}
    end)

    assert %Description{container: "kubernetes"} = Description.get_linux()
  end

  test "Linux inside Podman reports the podman runtime" do
    stub_linux({:ok, [{:stdout, ["podman"]}]})
    assert %Description{container: "podman"} = Description.get_linux()
  end

  test "Linux inside LXC reports the lxc runtime" do
    stub_linux({:ok, [{:stdout, ["lxc"]}]})
    assert %Description{container: "lxc"} = Description.get_linux()
  end

  test "detection runs once per process and is cached for later calls" do
    stub(Host.CommanderMock, :run, fn
      "if grep -qa kubepods" <> _, [:stdout, :sync] -> {:ok, [{:stdout, ["docker"]}]}
      @os_release, [:stdout, :sync] -> {:ok, [{:stdout, ["24.04.1 LTS (Noble Numbat)"]}]}
    end)

    assert %Description{container: "docker"} = Description.get_linux()

    # Stubbed to a different runtime: a cached call would still see the first result
    stub(Host.CommanderMock, :run, fn
      "if grep -qa kubepods" <> _, [:stdout, :sync] -> {:ok, [{:stdout, ["podman"]}]}
      @os_release, [:stdout, :sync] -> {:ok, [{:stdout, ["24.04.1 LTS (Noble Numbat)"]}]}
    end)

    assert %Description{container: "docker"} = Description.get_linux()
  end

  test "Linux reports no container runtime when the detection command fails" do
    stub_linux({:error, "any"})
    assert %Description{container: nil} = Description.get_linux()
  end

  test "macOS and Windows never report a container runtime" do
    stub(Host.CommanderMock, :run, fn "sw_vers -productVersion", [:stdout, :sync] ->
      {:ok, [{:stdout, ["15.7.4"]}]}
    end)

    assert %Description{host: "macOS", container: nil} = Description.get_macos()
    assert %Description{host: "Windows", container: nil} = Description.get_windows()
  end
end
