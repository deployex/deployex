defmodule DeployexWeb.HotUpgrade.StepsTest do
  use ExUnit.Case, async: true

  alias Deployer.HotUpgrade.Progress
  alias DeployexWeb.HotUpgrade.Steps

  # The messages of a self-upgrade, each one sent before its step runs
  @announced [
    "Starting upgrade for deployex...",
    "Unpacking release",
    "Creating relup file",
    "Checking release can be installed",
    "Resolving the runtime configuration",
    "Adding the runtime configuration to the relup",
    "Adding the version update to the relup",
    "Installing release",
    "Making release 0.10.1 permanent"
  ]

  defp run(state, messages), do: %Progress{state: state, messages: messages}
  defp first(n), do: Enum.take(@announced, n)
  defp states(progress), do: progress |> Steps.states() |> Enum.map(&elem(&1, 0))

  test "while running, the last message is the step in flight" do
    assert states(run(:running, [])) == [:current | List.duplicate(:pending, 8)]

    assert states(run(:running, first(2))) ==
             [
               :done,
               :current,
               :pending,
               :pending,
               :pending,
               :pending,
               :pending,
               :pending,
               :pending
             ]

    assert Steps.line(run(:running, first(2))) == "Step 2 of 9: Unpacking release"
  end

  test "on error, the step before the outcome failed" do
    progress = run(:error, first(4) ++ ["Hot upgrade 0.10.0 -> 0.10.1 failed: {:error, :boom}"])

    assert states(progress) ==
             [:done, :done, :done, :failed, :pending, :pending, :pending, :pending, :pending]

    assert Steps.line(progress) == "Failed at step 4 of 9: Checking release can be installed"
  end

  test "an error before any step names the first step" do
    assert [:failed | _] = states(run(:error, ["Hot upgrade failed: :not_connecting"]))
  end

  test "on success, every step is done" do
    progress = run(:success, first(9) ++ ["Hot upgrade applied successfully, 0.10.0 -> 0.10.1"])

    assert states(progress) == List.duplicate(:done, 9)
    assert Steps.at(progress) == 9
  end

  test "each message of a run is the step in flight, to the last one" do
    for {message, step} <- Enum.with_index(@announced, 1) do
      assert Steps.line(run(:running, first(step))) == "Step #{step} of 9: #{message}"
    end
  end

  test "an announced step has its message as the label, the others their name" do
    assert [
             {:done, "Starting upgrade for deployex..."},
             {:current, "Unpacking release"},
             {:pending, "Creating relup file"} | _
           ] = Steps.states(run(:running, first(2)))
  end
end
