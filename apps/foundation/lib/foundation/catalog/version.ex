defmodule Foundation.Catalog.Version do
  @moduledoc """
  Structure to handle the application version
  """
  @typedoc """
  `hot_upgrade_config_change` records what the release asked for in `current.json`: `true`,
  `false`, or `nil` when it did not say. A record written by an older version has no such key.

  `from_version` is the version a hot upgrade started from, `nil` for a full deployment. With
  `version` it names the relup of that upgrade, see `Foundation.Catalog.relup/3`.
  """
  @type t :: %__MODULE__{
          version: String.t() | nil,
          hash: String.t() | nil,
          pre_commands: list(),
          hot_upgrade_config_change: boolean() | nil,
          from_version: String.t() | nil,
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
            from_version: nil,
            name: "",
            sname: "",
            deployment: :full_deployment,
            inserted_at: nil
end
