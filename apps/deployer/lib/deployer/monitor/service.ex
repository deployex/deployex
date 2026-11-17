defmodule Deployer.Monitor.Service do
  @moduledoc """
  Structure to handle the monitor service structure
  """
  alias Foundation.Yaml.Liveness
  alias Foundation.Yaml.Readiness

  @type t :: %__MODULE__{
          name: String.t() | nil,
          sname: String.t() | nil,
          language: String.t() | nil,
          ports: list(),
          env: list(),
          readiness: Readiness.t(),
          liveness: Liveness.t() | nil,
          retry_delay_pre_commands: non_neg_integer()
        }

  @derive Jason.Encoder

  defstruct name: nil,
            sname: nil,
            language: nil,
            ports: [],
            env: [],
            readiness: %Readiness{},
            liveness: nil,
            retry_delay_pre_commands: :timer.seconds(1)
end
