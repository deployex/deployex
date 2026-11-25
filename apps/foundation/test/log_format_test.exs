defmodule Foundation.LogFormatTest do
  use ExUnit.Case, async: false

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

  for {format, module} <- [
        {"json", LoggerJSON.Formatters.Basic},
        {"datadog", LoggerJSON.Formatters.Datadog},
        {"gcp", LoggerJSON.Formatters.GoogleCloud},
        {"elastic", LoggerJSON.Formatters.Elastic}
      ] do
    test "apply/1 with #{format} writes one JSON object a line, with the service" do
      assert LogFormat.apply(unquote(format)) == unquote(format)
      assert {unquote(module), config} = formatter()
      assert %{service: "deployex"} = :logger.get_primary_config().metadata

      # What the handler writes for an event, with the metadata the primary config adds
      event = %{
        level: :info,
        msg: {:string, "Update is needed"},
        meta: %{time: System.os_time(:microsecond), service: "deployex", pid: self()}
      }

      line = event |> unquote(module).format(config) |> IO.iodata_to_binary()

      assert String.ends_with?(line, "\n")
      assert %{"message" => "Update is needed"} = decoded = Jason.decode!(line)
      assert line =~ ~s("service":"deployex")
      assert is_map(decoded)
    end
  end
end
