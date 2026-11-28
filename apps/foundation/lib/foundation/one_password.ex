defmodule Foundation.OnePassword do
  @moduledoc """
  What the 1Password adapters share: the path of an item, and what its fields become.

  An item is addressed as `vaults/<vault>/items/<item>`, the format the 1Password Kubernetes
  operator uses in its `item-path` annotation. Each part is a name or an ID.

  The fields of the item are returned as a map of label to value. A monitored application
  gets them as environment variables, see `to_env/1`.
  """

  require Logger

  alias Foundation.ConfigProvider.Secrets.EnvName

  @path_format "vaults/<vault>/items/<item>"

  @type fields :: %{optional(String.t()) => String.t()}

  @doc """
  Splits the path of an item into its vault and its item.

  ## Examples

      iex> Foundation.OnePassword.parse_path("vaults/production/items/myphoenixapp")
      {:ok, "production", "myphoenixapp"}
      iex> Foundation.OnePassword.parse_path("vaults/My Vault/items/My App")
      {:ok, "My Vault", "My App"}
      iex> Foundation.OnePassword.parse_path("production/myphoenixapp")
      {:error, :invalid_path}
      iex> Foundation.OnePassword.parse_path("vaults//items/myphoenixapp")
      {:error, :invalid_path}
      iex> Foundation.OnePassword.parse_path(nil)
      {:error, :invalid_path}
  """
  @spec parse_path(any()) :: {:ok, String.t(), String.t()} | {:error, :invalid_path}
  def parse_path(path) when is_binary(path) do
    case String.split(path, "/") do
      ["vaults", vault, "items", item] when vault != "" and item != "" -> {:ok, vault, item}
      _other -> {:error, :invalid_path}
    end
  end

  def parse_path(_path), do: {:error, :invalid_path}

  @doc """
  The message for a path that `parse_path/1` rejects.
  """
  @spec path_error(any()) :: String.t()
  def path_error(path),
    do: "1Password path #{inspect(path)} not supported, expected #{@path_format}"

  @doc """
  Turns the `fields` of an item, as the Connect server and the `op` CLI return them, into a
  map of label to value.

  A field without a label or without a value is left out, and when two fields have the same
  label the later one wins, both as the 1Password Kubernetes operator does. The notes of the
  item are left out too, which the operator does not do. URLs and file attachments are not
  read.

  ## Examples

      iex> Foundation.OnePassword.fields_to_map([
      ...>   %{"id" => "notesPlain", "label" => "notesPlain", "purpose" => "NOTES", "value" => "a note"},
      ...>   %{"id" => "abc", "label" => "DATABASE_URL", "type" => "CONCEALED", "value" => "ecto://db"},
      ...>   %{"id" => "def", "label" => "EMPTY", "type" => "STRING"},
      ...>   %{"id" => "ghi", "label" => "DATABASE_URL", "value" => "second"}
      ...> ])
      %{"DATABASE_URL" => "second"}
  """
  @spec fields_to_map(any()) :: fields()
  def fields_to_map(fields) when is_list(fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      case field do
        %{"purpose" => "NOTES"} ->
          acc

        %{"label" => label, "value" => value}
        when is_binary(label) and label != "" and is_binary(value) and value != "" ->
          Map.put(acc, label, value)

        _without_label_or_value ->
          acc
      end
    end)
  end

  def fields_to_map(_fields), do: %{}

  @doc """
  The environment variables a monitored application gets from the fields of its item, sorted
  by name.

  A field whose label is not a valid variable name is left out, and so is one that starts
  with `RELEASE_` or `DEPLOYEX_`, which DeployEx removes from the environment of every
  application it starts. The names left out are logged, the values never are.

  ## Examples

      iex> Foundation.OnePassword.to_env(%{"SECRET_KEY_BASE" => "abc", "DATABASE_URL" => "ecto://db"})
      [{"DATABASE_URL", "ecto://db"}, {"SECRET_KEY_BASE", "abc"}]
  """
  @spec to_env(fields()) :: [{String.t(), String.t()}]
  def to_env(fields) do
    {env, skipped} =
      fields
      |> Enum.sort()
      |> Enum.split_with(fn {name, _value} -> EnvName.valid?(name) end)

    if skipped != [] do
      Logger.warning(
        "1Password fields not passed to the application, their labels are not usable as " <>
          "environment variables: #{skipped |> Enum.map(&elem(&1, 0)) |> inspect()}"
      )
    end

    env
  end
end
