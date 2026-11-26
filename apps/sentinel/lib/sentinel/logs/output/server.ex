defmodule Sentinel.Logs.Output.Server do
  @moduledoc """
  Writes what the monitored applications print to the output of DeployEx itself, when
  `monitored_app_log_stdout` is on.

  In a container, what collects the logs reads the output of its main process, which is
  DeployEx, and the applications write to files. `Sentinel.Logs.Server` hands each piece
  it reads from those files to this server, which writes it without a prefix, since one
  would break the lines of an application that logs JSON.

  A piece is not always a whole line, and DeployEx and every application share the same
  output, so only whole lines are written: the end of a piece that has no line break is
  kept, for each application and each of its outputs, until the rest of the line comes.
  That also keeps a character that was cut between two pieces in one write. What is kept
  is written anyway after `flush_interval`, for an application that prints without a line
  break.

  The write is done here and not in `Sentinel.Logs.Server` because the output can make
  the writer wait, and the logs of the dashboard must not wait with it. While this server
  waits, the pieces that come over `max_pending` are dropped instead of kept in memory.
  """
  use GenServer

  @flush_interval 1_000
  @max_pending 5_000

  @type t :: %__MODULE__{
          buffers: %{{String.t(), String.t()} => binary()},
          flush_interval: non_neg_integer(),
          flush_timer_ref: nil | reference()
        }

  defstruct buffers: %{},
            flush_interval: @flush_interval,
            flush_timer_ref: nil

  ### ==========================================================================
  ### Callback functions
  ### ==========================================================================
  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    name = Keyword.get(args, :name, __MODULE__)

    GenServer.start_link(__MODULE__, args, name: name)
  end

  @impl true
  def init(args) do
    {:ok, %__MODULE__{flush_interval: Keyword.get(args, :flush_interval, @flush_interval)}}
  end

  @impl true
  def handle_cast({:forward, sname, log_key, message}, %__MODULE__{buffers: buffers} = state) do
    key = {sname, log_key}
    {lines, rest} = split_whole_lines(Map.get(buffers, key, "") <> message)

    write(log_key, lines)

    {:noreply, schedule_flush(%{state | buffers: keep(buffers, key, rest)})}
  end

  @impl true
  def handle_info(:flush, %__MODULE__{buffers: buffers} = state) do
    buffers =
      Enum.reduce(buffers, %{}, fn {{_sname, log_key} = key, data}, acc ->
        {characters, rest} = split_whole_characters(data)
        write(log_key, characters)
        keep(acc, key, rest)
      end)

    {:noreply, %{state | buffers: buffers, flush_timer_ref: nil}}
  end

  ### ==========================================================================
  ### Public functions
  ### ==========================================================================

  @doc """
  Hands a piece of the output of an application to the server, without waiting for it.

  Nothing is done when `monitored_app_log_stdout` is off, when the server is not running
  or when it already has too many pieces waiting.
  """
  @spec forward(String.t(), String.t(), any(), GenServer.server()) :: :ok
  def forward(sname, log_key, message, server \\ __MODULE__)

  def forward(sname, log_key, message, server) when is_binary(message) do
    with true <- Application.get_env(:foundation, :monitored_app_log_stdout, false),
         pid when is_pid(pid) <- GenServer.whereis(server),
         {:message_queue_len, pending} when pending < @max_pending <-
           Process.info(pid, :message_queue_len) do
      GenServer.cast(pid, {:forward, sname, log_key, message})
    else
      _skip -> :ok
    end
  end

  def forward(_sname, _log_key, _message, _server), do: :ok

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================
  defp keep(buffers, key, ""), do: Map.delete(buffers, key)
  defp keep(buffers, key, rest), do: Map.put(buffers, key, rest)

  defp schedule_flush(%__MODULE__{buffers: buffers, flush_timer_ref: nil} = state)
       when map_size(buffers) > 0 do
    %{state | flush_timer_ref: Process.send_after(self(), :flush, state.flush_interval)}
  end

  defp schedule_flush(state), do: state

  # Everything up to the last line break, and what follows it
  defp split_whole_lines(data) do
    case :binary.matches(data, "\n") do
      [] ->
        {"", data}

      matches ->
        {position, 1} = List.last(matches)
        size = position + 1

        {binary_part(data, 0, size), binary_part(data, size, byte_size(data) - size)}
    end
  end

  # The bytes of a character whose end has not come yet stay for the next piece
  defp split_whole_characters(data) do
    case :unicode.characters_to_binary(data) do
      {:incomplete, characters, rest} -> {characters, rest}
      _complete_or_invalid -> {data, ""}
    end
  end

  defp write(_log_key, ""), do: :ok

  defp write(log_key, data) do
    device = if log_key == "stderr", do: :stderr, else: :stdio

    # The output takes characters: bytes that are not UTF-8 would be read as Latin-1 and
    # encoded again, so they are replaced
    IO.write(device, String.replace_invalid(data))
  rescue
    # A closed output must not stop this server
    _error -> :ok
  end
end
