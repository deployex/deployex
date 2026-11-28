defmodule Host.Info.Description do
  @moduledoc """
  Reads host description across Linux, macOS, and Windows platforms, including
  whether the Linux host is itself a container (Docker, Podman, Kubernetes, LXC).
  """

  alias Host.Commander

  @type t :: %__MODULE__{
          host: String.t(),
          description: nil | String.t(),
          container: nil | String.t()
        }

  defstruct host: "",
            description: nil,
            container: nil

  ### ==========================================================================
  ### Public APIs
  ### ==========================================================================

  @spec get_linux() :: t()
  def get_linux do
    container = container_runtime()

    case Commander.run("cat /etc/os-release | grep VERSION= | sed 's/VERSION=//; s/\"//g'", [
           :stdout,
           :sync
         ]) do
      {:ok, [{:stdout, stdout}]} ->
        description = stdout |> Enum.join() |> String.trim()

        %__MODULE__{host: "Linux", description: description, container: container}

      _ ->
        %__MODULE__{host: "Linux", container: container}
    end
  end

  @spec get_macos() :: t()
  def get_macos do
    case Commander.run("sw_vers -productVersion", [:stdout, :sync]) do
      {:ok, [{:stdout, stdout}]} ->
        description = stdout |> Enum.join() |> String.trim()

        %__MODULE__{host: "macOS", description: description}

      _ ->
        %__MODULE__{host: "macOS"}
    end
  end

  @spec get_windows() :: t()
  def get_windows, do: %__MODULE__{host: "Windows"}

  ### ==========================================================================
  ### Private Functions
  ### ==========================================================================

  # /.dockerenv and /run/.containerenv are the markers Docker and Podman each drop into every
  # container they start. /proc/1/cgroup is the fallback for runtimes that drop neither, such as
  # containerd or LXC, and for Kubernetes, whose pods are still Docker/containerd underneath.
  defp container_runtime do
    command = """
    if [ -f /.dockerenv ]; then echo docker
    elif [ -f /run/.containerenv ]; then echo podman
    elif grep -qa kubepods /proc/1/cgroup 2>/dev/null; then echo kubernetes
    elif grep -qaE 'docker|containerd' /proc/1/cgroup 2>/dev/null; then echo docker
    elif grep -qa /lxc/ /proc/1/cgroup 2>/dev/null; then echo lxc
    else echo none
    fi
    """

    case Commander.run(command, [:stdout, :sync]) do
      {:ok, [{:stdout, stdout}]} ->
        case stdout |> Enum.join() |> String.trim() do
          "none" -> nil
          runtime -> runtime
        end

      _ ->
        nil
    end
  end
end
