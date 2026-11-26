defmodule Foundation.LogFormatTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Foundation.LogFormat

  setup do
    {:ok, handler} = :logger.get_handler_config(:default)
    primary = :logger.get_primary_config()

    on_exit(fn ->
      :ok = :logger.update_handler_config(:default, :formatter, handler.formatter)
      :ok = :logger.set_primary_config(primary)
      Application.delete_env(:foundation, :log_format)
    end)

    {:ok, formatter: handler.formatter}
  end

  defp formatter, do: :logger.get_handler_config(:default) |> elem(1) |> Map.fetch!(:formatter)

  test "formats/0 has text first, then the JSON shapes" do
    assert LogFormat.formats() == ["text", "datadog", "elastic", "gcp", "json"]
  end

  test "apply/0 leaves the logger as it is without the option, or with text", context do
    assert LogFormat.apply() == "text"
    assert LogFormat.apply("text") == "text"
    assert LogFormat.apply("xml") == "text"
    assert formatter() == context.formatter
    refute Map.has_key?(Map.get(:logger.get_primary_config(), :metadata, %{}), :service)
  end

  test "apply/0 reads the format the YAML set" do
    Application.put_env(:foundation, :log_format, "datadog")

    assert LogFormat.apply() == "datadog"
    assert {LoggerJSON.Formatters.Datadog, _config} = formatter()
  end

  test "apply/1 has the service under one key when the format is changed" do
    assert LogFormat.apply("elastic") == "elastic"
    assert LogFormat.apply("datadog") == "datadog"

    metadata = :logger.get_primary_config().metadata
    assert metadata.service == "deployex"
    refute Map.has_key?(metadata, :"service.name")
  end

  test "apply/1 leaves the logger as it is when it has no default handler" do
    {:ok, handler} = :logger.get_handler_config(:default)
    :ok = :logger.remove_handler(:default)

    try do
      log = capture_log(fn -> assert LogFormat.apply("datadog") == "text" end)

      assert log =~ "log_format datadog is not set"
      refute Map.has_key?(Map.get(:logger.get_primary_config(), :metadata, %{}), :service)
    after
      :ok = :logger.add_handler(:default, handler.module, handler)
    end
  end

  # What the handler writes for an event, with the metadata the primary config adds
  defp line(module, config) do
    event = %{
      level: :info,
      msg: {:string, "Update is needed"},
      meta:
        Map.merge(:logger.get_primary_config().metadata, %{
          time: System.os_time(:microsecond),
          pid: self(),
          mfa: {__MODULE__, :line, 2},
          file: ~c"log_format_test.exs",
          line: 1
        })
    }

    line = event |> module.format(config) |> IO.iodata_to_binary()
    assert String.ends_with?(line, "\n")

    Jason.decode!(line)
  end

  for {format, module} <- [
        {"json", LoggerJSON.Formatters.Basic},
        {"datadog", LoggerJSON.Formatters.Datadog},
        {"gcp", LoggerJSON.Formatters.GoogleCloud},
        {"elastic", LoggerJSON.Formatters.Elastic}
      ] do
    test "apply/1 with #{format} writes one JSON object a line" do
      assert LogFormat.apply(unquote(format)) == unquote(format)
      assert {unquote(module), config} = formatter()

      assert %{"message" => "Update is needed"} = line(unquote(module), config)
    end
  end

  test "json has the service, the process and the function in its metadata" do
    LogFormat.apply("json")
    {module, config} = formatter()

    assert %{"metadata" => metadata} = line(module, config)
    assert metadata["service"] == "deployex"
    assert metadata["pid"] == inspect(self())
    assert metadata["mfa"] == "Elixir.Foundation.LogFormatTest.line/2"
  end

  test "datadog has the service, and the process and the function in its logger" do
    LogFormat.apply("datadog")
    {module, config} = formatter()

    assert %{"service" => "deployex", "logger" => logger} = line(module, config)
    assert logger["thread_name"] == inspect(self())
    assert logger["method_name"] =~ "Foundation.LogFormatTest.line/2"
  end

  test "gcp has the service, also as the one of the errors it reports" do
    LogFormat.apply("gcp")
    {module, config} = formatter()

    assert config.service_context == %{service: "deployex"}
    assert %{"service" => "deployex"} = decoded = line(module, config)
    assert decoded["logging.googleapis.com/operation"]["producer"] == inspect(self())
  end

  test "elastic has the service as service.name, since service is an object there" do
    LogFormat.apply("elastic")
    {module, config} = formatter()

    assert %{"service.name" => "deployex"} = decoded = line(module, config)
    refute Map.has_key?(decoded, "service")
    assert decoded["pid"] == inspect(self())
    assert decoded["log.logger"] == "Elixir.Foundation.LogFormatTest"
  end
end
