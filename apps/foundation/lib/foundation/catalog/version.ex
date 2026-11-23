defmodule Foundation.Catalog.Version do
  @moduledoc """
  Structure to handle the application version
  """
  @typedoc """
  `hot_upgrade_config_change` records what the release asked for in `current.json`: `true`,
  `false`, or `nil` when it did not say. A record written by an older version has no such key.
  """
  @type t :: %__MODULE__{
          version: String.t() | nil,
          hash: String.t() | nil,
          pre_commands: list(),
          hot_upgrade_config_change: boolean() | nil,
          name: String.t(),
          sname: String.t(),
          deployment: :full_deployment | :hot_upgrade,
          inserted_at: NaiveDateTime.t() | nil
        }

  @derive Jason.Encoder

  defstruct version: nil,
            hash: nil,
            pre_commands: [],
            hot_upgrade_config_change: nil,
            name: "",
            sname: "",
            deployment: :full_deployment,
            inserted_at: nil
end
