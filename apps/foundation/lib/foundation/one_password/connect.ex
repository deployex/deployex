defmodule Foundation.OnePassword.Connect do
  @moduledoc """
  Reads an item from a 1Password Connect server over its REST API.

  The server and its token come from the environment of DeployEx, under the names the
  1Password tools use: `OP_CONNECT_HOST` and `OP_CONNECT_TOKEN`.

  A vault or an item given by name is looked up first, since the API addresses both by ID.
  When several share the name, the oldest one is used.
  """

  alias Foundation.OnePassword

  @finch FinchOnePasswordConnectClient
  @timeout_ms 10_000

  # 1Password IDs are 26 lowercase letters and digits
  @id ~r/^[a-z0-9]{26}$/

  @doc """
  The fields of the item at `path`, as a map of label to value.

  An error names what could not be read, never a value of the item.
  """
  @spec fetch(String.t()) :: {:ok, OnePassword.fields()} | {:error, any()}
  def fetch(path) do
    with {:ok, vault, item} <- OnePassword.parse_path(path),
         {:ok, host, token} <- credentials() do
      with_client(fn ->
        with {:ok, vault_id} <- vault_id(host, token, vault),
             {:ok, item_id} <- item_id(host, token, vault_id, item),
             {:ok, %{"fields" => fields}} <-
               get(host, token, "/v1/vaults/#{vault_id}/items/#{item_id}") do
          {:ok, OnePassword.fields_to_map(fields)}
        else
          {:ok, _item_without_fields} -> {:ok, %{}}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp credentials do
    host = System.get_env("OP_CONNECT_HOST")
    token = System.get_env("OP_CONNECT_TOKEN")

    if host in [nil, ""] or token in [nil, ""] do
      {:error, {:missing_env, ["OP_CONNECT_HOST", "OP_CONNECT_TOKEN"]}}
    else
      {:ok, String.trim_trailing(host, "/"), token}
    end
  end

  # The config provider runs before any application is started, and the monitor calls this
  # a few times a day at most, so the connection pool only lives for the call
  defp with_client(fun) do
    {:ok, _} = Application.ensure_all_started(:finch)
    {:ok, sup} = Supervisor.start_link([{Finch, name: @finch}], strategy: :one_for_one)

    try do
      fun.()
    after
      Supervisor.stop(sup, :normal)
    end
  end

  # A vault is matched by name first, a name can look like an ID. The names are compared
  # here: the API reference filters vaults on `name` and the official SDK on `title`
  defp vault_id(host, token, vault) do
    case get(host, token, "/v1/vaults") do
      {:ok, vaults} when is_list(vaults) ->
        case vaults |> Enum.filter(&(&1["name"] == vault)) |> oldest() do
          %{"id" => id} -> {:ok, id}
          nil -> if id?(vault), do: {:ok, vault}, else: {:error, {:not_found, :vault, vault}}
        end

      {:ok, _not_a_list} ->
        {:error, {:unexpected_response, :vault}}

      {:error, _reason} = error ->
        error
    end
  end

  # An item is taken as an ID first when it looks like one, and as a title when no item has
  # that ID
  defp item_id(host, token, vault_id, item) do
    if id?(item) do
      case get(host, token, "/v1/vaults/#{vault_id}/items/#{item}") do
        {:ok, %{"id" => id}} -> {:ok, id}
        {:error, {:http_status, 404, _path}} -> item_id_by_title(host, token, vault_id, item)
        {:ok, _other} -> {:error, {:unexpected_response, :item}}
        {:error, _reason} = error -> error
      end
    else
      item_id_by_title(host, token, vault_id, item)
    end
  end

  # The filter is SCIM syntax, with the value in double quotes. The list has no fields, the
  # item is read by its ID afterwards
  defp item_id_by_title(host, token, vault_id, title) do
    query = URI.encode_query(%{"filter" => ~s(title eq "#{title}")})

    case get(host, token, "/v1/vaults/#{vault_id}/items?#{query}") do
      {:ok, items} when is_list(items) ->
        case items |> Enum.filter(&(&1["title"] == title)) |> oldest() do
          %{"id" => id} -> {:ok, id}
          nil -> {:error, {:not_found, :item, title}}
        end

      {:ok, _not_a_list} ->
        {:error, {:unexpected_response, :item}}

      {:error, _reason} = error ->
        error
    end
  end

  defp id?(value), do: Regex.match?(@id, value)

  # Several vaults or items can share a name. The oldest one is used, as the 1Password
  # Kubernetes operator does
  defp oldest([]), do: nil
  defp oldest(entries), do: Enum.min_by(entries, &(&1["createdAt"] || ""))

  defp get(host, token, path) do
    headers = [{"authorization", "Bearer #{token}"}, {"accept", "application/json"}]

    :get
    |> Finch.build(host <> path, headers)
    |> Finch.request(@finch, receive_timeout: @timeout_ms)
    |> case do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        decode(body)

      # The body of an error can echo the request, the status says enough
      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_status, status, path_without_query(path)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp path_without_query(path), do: path |> String.split("?") |> hd()
end
