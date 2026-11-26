defmodule Foundation.LogFormat do
  @moduledoc """
  The format of the logs DeployEx writes to its output.

  It is text unless `log_format` in the YAML asks for JSON, one object a line, which is what
  a log collector reads from the output of a container. The shapes are the ones of
  [LoggerJSON](https://hexdocs.pm/logger_json):

    * `"json"` - `LoggerJSON.Formatters.Basic`
    * `"datadog"` - `LoggerJSON.Formatters.Datadog`
    * `"gcp"` - `LoggerJSON.Formatters.GoogleCloud`
    * `"elastic"` - `LoggerJSON.Formatters.Elastic`

  Every line has the service, `"deployex"`, so the lines of DeployEx can be told from the ones
  of an application that are in the same output, see `monitored_app_log_stdout`. It is
  `service`, and `service.name` with `"elastic"`: in the Elastic Common Schema `service` is
  an object, and a line where it is a string is refused. With `"gcp"` it is also the service
  of the errors that are reported.

  A line also has what the text format has: the instance, the process and the function that
  logged. Each formatter puts the last two where its shape has a place for them.

  The format is set when the `foundation` application starts, which is the first of DeployEx.
  What the VM logs before that, while it boots, is text.
  """

  require Logger

  @service "deployex"
  @metadata [:instance, :sname, :name, :pid, :mfa]

  # The formatter of each format, and the key it has the service under
  @formatters %{
    "json" => {LoggerJSON.Formatters.Basic, :service},
    "datadog" => {LoggerJSON.Formatters.Datadog, :service},
    "gcp" => {LoggerJSON.Formatters.GoogleCloud, :service},
    "elastic" => {LoggerJSON.Formatters.Elastic, :"service.name"}
  }
  @service_keys @formatters |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

  @doc """
  The values `log_format` takes in the YAML, `"text"` being the default.
  """
  @spec formats() :: [String.t()]
  def formats, do: ["text" | @formatters |> Map.keys() |> Enum.sort()]

  @doc """
  Sets the format the YAML asked for on the default handler of the logger.

  It returns the format that is in place. With `"text"`, or a value it does not know, the
  logger is left as it is. It is too when the logger has no default handler, which is logged
  and does not stop DeployEx from starting.
  """
  @spec apply() :: String.t()
  def apply, do: apply(Application.get_env(:foundation, :log_format, "text"))

  @spec apply(String.t() | nil) :: String.t()
  def apply(format) do
    case Map.fetch(@formatters, format) do
      {:ok, {module, service_key}} -> set(format, module, service_key)
      :error -> "text"
    end
  end

  defp set(format, module, service_key) do
    formatter = module.new(options(module, service_key))

    case :logger.update_handler_config(:default, :formatter, formatter) do
      :ok ->
        # The service is metadata of every event, whichever process logs it
        metadata =
          :logger.get_primary_config()
          |> Map.get(:metadata, %{})
          |> Map.drop(@service_keys)
          |> Map.put(service_key, @service)

        :ok = :logger.update_primary_config(%{metadata: metadata})

        format

      {:error, reason} ->
        Logger.warning(
          "log_format #{format} is not set, the logs stay as they are: #{inspect(reason)}"
        )

        "text"
    end
  end

  defp options(LoggerJSON.Formatters.GoogleCloud, service_key) do
    [metadata: [service_key | @metadata], service_context: %{service: @service}]
  end

  defp options(_module, service_key), do: [metadata: [service_key | @metadata]]
end
