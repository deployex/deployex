defmodule Deployer.Release.Version do
  @moduledoc """
  Structure to handle the version structure
  """
  @typedoc """
  `hot_upgrade_config_change` is what the release asks for in `current.json`: `true` or `false`,
  or `nil` when it does not say, which is not asking.
  """
  @type t :: %__MODULE__{
          version: String.t() | nil,
          hash: String.t() | nil,
          pre_commands: list(),
          hot_upgrade_config_change: boolean() | nil
        }

  @derive Jason.Encoder

  defstruct version: nil,
            hash: nil,
            pre_commands: [],
            hot_upgrade_config_change: nil
end
