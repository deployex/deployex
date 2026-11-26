defmodule DeployexWeb.LogLinesTest do
  use ExUnit.Case, async: true

  alias DeployexWeb.LogLines

  @error "var(--dx-error-text)"
  @warning "var(--dx-warning-text)"
  @base "var(--dx-base-content)"

  defp color(text), do: LogLines.color(%{type: "stdout", text: text})

  describe "color/1" do
    test "reads the level of a line of text" do
      assert color("12:00:00.000 [error] it failed") == @error
      assert color("12:00:00.000 [warning] it may fail") == @warning
      assert color("12:00:00.000 [info] it works") == @base
    end

    test "reads the level of a line DeployEx wrote as JSON, in each format" do
      # json and gcp
      assert color(~s({"message":"it failed","severity":"error","time":"2026-11-25"})) == @error
      assert color(~s({"message":"it failed","severity":"ERROR"})) == @error
      assert color(~s({"message":"it may fail","severity":"WARNING"})) == @warning
      # datadog
      assert color(~s({"message":"it failed","syslog":{"hostname":"h","severity":"critical"}})) ==
               @error

      # elastic
      assert color(~s({"@timestamp":"2026-11-25","log.level":"warning","message":"it may"})) ==
               @warning

      assert color(~s({"message":"it works","severity":"info"})) == @base
    end

    test "reads the level of a JSON line that has spaces" do
      assert color(~s({"level": "error", "msg": "it failed"})) == @error
    end

    test "a line that only talks about a level has no color" do
      assert color(~s({"message":"no level here"})) == @base
      assert color(~s(the "severity":"error" of a line that is not JSON)) == @base
    end

    test "stderr is an error whatever it says" do
      assert LogLines.color(%{type: "stderr", text: ~s({"severity":"info"})}) == @error
    end
  end
end
