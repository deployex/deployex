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

  Every line has `service: "deployex"`, so the lines of DeployEx can be told from the ones of
  an application that are in the same output, see `monitored_app_log_stdout`.

  The format is set when the `foundation` application starts, which is the first of DeployEx.
  What the VM logs before that, while it boots, is text.
  """

  @service "deployex"
  @metadata [:service, :instance, :sname, :name]

  @formatters %{
    "json" => LoggerJSON.Formatters.Basic,
    "datadog" => LoggerJSON.Formatters.Datadog,
    "gcp" => LoggerJSON.Formatters.GoogleCloud,
    "elastic" => LoggerJSON.Formatters.Elastic
  }

  @doc """
  The values `log_format` takes in the YAML, `"text"` being the default.
  """
  @spec formats() :: [String.t()]
  def formats, do: ["text" | @formatters |> Map.keys() |> Enum.sort()]

  @doc """
  Sets the format the YAML asked for on the default handler of the logger.

  It returns the format that is in place. With `"text"`, or a value it does not know, the
  logger is left as it is.
  """
  @spec apply() :: String.t()
  def apply, do: apply(Application.get_env(:foundation, :log_format, "text"))

  @spec apply(String.t() | nil) :: String.t()
  def apply(format) do
    case Map.fetch(@formatters, format) do
      {:ok, formatter} ->
        # The service is metadata of every event, whichever process logs it
        primary = :logger.get_primary_config()
        metadata = primary |> Map.get(:metadata, %{}) |> Map.put(:service, @service)
        :ok = :logger.update_primary_config(%{metadata: metadata})

        :ok =
          :logger.update_handler_config(:default, :formatter, formatter.new(metadata: @metadata))

        format

      :error ->
        "text"
    end
  end
end
