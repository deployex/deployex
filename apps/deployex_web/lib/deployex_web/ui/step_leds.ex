defmodule DeployexWeb.UI.StepLeds do
  @moduledoc """
  A row of square LEDs, one per hot-upgrade step, read at a glance next to the
  text log in DeployexWeb.HotUpgradeLive.
  """
  use Phoenix.Component

  @doc """
  Renders one square per step, derived from the same assigns that already drive
  the text log: `progress` (the messages received so far), `state` (`:running`,
  `:success` or `:error`) and `total` (the step count).
  """
  attr :id, :string, required: true
  attr :progress, :list, required: true
  attr :state, :atom, required: true, values: [:running, :success, :error]
  attr :total, :integer, required: true

  def row(assigns) do
    assigns = assign(assigns, :steps, step_states(assigns.progress, assigns.state, assigns.total))

    ~H"""
    <div id={@id} class="dx-leds" role="list" aria-label="Upgrade steps">
      <span
        :for={{step, index} <- Enum.with_index(@steps, 1)}
        role="listitem"
        class={["dx-led", "dx-led-#{step}"]}
        aria-label={"Step #{index}: #{step}"}
      ></span>
    </div>
    """
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
end
