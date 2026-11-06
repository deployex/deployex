defmodule DeployexWeb.UI.StepLeds do
  @moduledoc """
  A row of square LEDs, one per hot-upgrade step, read at a glance next to the
  current-step line in DeployexWeb.HotUpgradeLive. Each LED carries a tooltip
  naming its step, so the row stays informative without a growing text log.
  """
  use Phoenix.Component

  @step_names [
    "Starting the upgrade",
    "Unpacking release",
    "Creating relup file",
    "Checking release can be installed",
    "Resolving the runtime configuration",
    "Adding the runtime configuration to the relup",
    "Installing release",
    "Making the release permanent"
  ]

  @doc """
  Renders one square per step, each with a tooltip naming it. Derived from the
  same assigns that drive the modal: `progress` (the messages received so
  far), `state` (`:running`, `:success` or `:error`) and `total` (the step
  count).
  """
  attr :id, :string, required: true
  attr :progress, :list, required: true
  attr :state, :atom, required: true, values: [:running, :success, :error]
  attr :total, :integer, required: true

  def row(assigns) do
    assigns =
      assign(
        assigns,
        :items,
        step_labels(assigns.progress, assigns.state, assigns.total) |> Enum.with_index(1)
      )

    ~H"""
    <div id={@id} class="dx-leds" role="list" aria-label="Upgrade steps">
      <span
        :for={{{step, label}, index} <- @items}
        id={"#{@id}-#{index}"}
        phx-hook="Tip"
        class="dx-led-wrap"
      >
        <span
          role="listitem"
          tabindex="0"
          class={["dx-led", "dx-led-#{step}"]}
          aria-label={"Step #{index}: #{label}"}
        ></span>
        <span popover="manual" class="dx-tip" aria-hidden="true">{label}</span>
      </span>
    </div>
    """
  end

  @doc """
  The name of the step currently in flight, for the status line that stays
  next to the LEDs while running, so the user always sees what is happening.
  """
  @spec current_step(list(String.t()), pos_integer()) :: String.t()
  def current_step(progress, total) do
    index = length(progress) + 1

    if index <= total, do: static_name(index), else: "Finishing up"
  end

  @doc """
  One `{state, label}` pair per step. The label is the real message received
  for a step that already ran or failed, since that carries the exact detail
  (including the failure reason); every other step - current, pending, or
  skipped - has no message yet, so it falls back to the step's static name.
  """
  @spec step_labels(list(String.t()), :running | :success | :error, pos_integer()) ::
          list({:pending | :current | :done | :failed | :skipped, String.t()})
  def step_labels(progress, state, total) do
    step_states(progress, state, total)
    |> Enum.with_index(1)
    |> Enum.map(fn {step_state, index} ->
      {step_state, label_for(step_state, index, progress)}
    end)
  end

  @doc """
  One state per step: `:pending`, `:current`, `:done`, `:failed` or `:skipped`.

  Every message in `progress` corresponds to a step either starting (while
  running) or to the final outcome replacing the step that was in flight
  (on error), or being appended after the last step (on success). Make
  permanent, the last step, is sometimes not sent at all when the caller
  asked for it to run asynchronously, which, on success, surfaces as one
  fewer message than `total` and marks that step `:skipped` instead of
  leaving it `:pending` forever.
  """
  @spec step_states(list(String.t()), :running | :success | :error, pos_integer()) ::
          list(:pending | :current | :done | :failed | :skipped)
  def step_states(progress, state, total) do
    received = length(progress)

    for step <- 1..total, do: step_state(step, received, state, total)
  end

  defp step_state(step, received, :running, _total) do
    cond do
      step <= received -> :done
      step == received + 1 -> :current
      true -> :pending
    end
  end

  defp step_state(step, received, :error, _total) do
    cond do
      step < received -> :done
      step == received -> :failed
      true -> :pending
    end
  end

  defp step_state(step, received, :success, total) do
    done = received - 1

    cond do
      step <= done -> :done
      step == total and done == total - 1 -> :skipped
      true -> :pending
    end
  end

  defp label_for(:skipped, _index, _progress),
    do: "Making the release permanent - skipped, done asynchronously"

  defp label_for(step_state, index, progress) when step_state in [:done, :failed] do
    Enum.at(progress, index - 1) || static_name(index)
  end

  defp label_for(_step_state, index, _progress), do: static_name(index)

  defp static_name(index), do: Enum.at(@step_names, index - 1, "Step #{index}")
end
