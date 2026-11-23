defmodule Foundation.OnePassword.ConnectTest do
  use ExUnit.Case, async: false

  import Mock

  alias Foundation.OnePassword.Connect

  @host "http://connect.internal:8080"
  @vault_id "ftz4pm2xxwmwrsd7rjqn7grzfz"
  @item_id "2fcbqwe9ndg175zg2dzwftvkpa"
  @path "vaults/production/items/myphoenixapp"

  @item %{
    "id" => @item_id,
    "title" => "myphoenixapp",
    "fields" => [
      %{"id" => "notesPlain", "type" => "STRING", "purpose" => "NOTES", "label" => "notesPlain"},
      %{"id" => "a", "type" => "CONCEALED", "label" => "DATABASE_URL", "value" => "ecto://db"},
      %{"id" => "b", "type" => "STRING", "label" => "PHX_HOST", "value" => "example.com"}
    ]
  }

  # The responses of the Connect server, by request path. A request to any other path fails
  # the test, so each test also pins the requests that are made
  defp with_connect(responses, env, fun) do
    test_pid = self()

    with_mocks([
      {System, [:passthrough], [get_env: fn name -> env[name] end]},
      {Supervisor, [:passthrough],
       [
         start_link: fn _children, _options -> {:ok, test_pid} end,
         stop: fn _pid, :normal -> :ok end
       ]},
      {Finch, [:passthrough],
       [
         build: fn :get, url, headers -> {url, headers} end,
         request: fn {url, headers}, _name, _options ->
           send(test_pid, {:request, String.replace_prefix(url, @host, ""), headers})

           case Map.fetch(responses, String.replace_prefix(url, @host, "")) do
             {:ok, {:error, reason}} -> {:error, reason}
             {:ok, {status, body}} -> {:ok, %Finch.Response{status: status, body: body}}
             {:ok, body} -> {:ok, %Finch.Response{status: 200, body: Jason.encode!(body)}}
             :error -> flunk("unexpected request to #{url}")
           end
         end
       ]}
    ]) do
      fun.()
    end
  end

  defp credentials,
    do: %{"OP_CONNECT_HOST" => @host <> "/", "OP_CONNECT_TOKEN" => "connect-token"}

  defp item_filter(title),
    do:
      "/v1/vaults/#{@vault_id}/items?" <> URI.encode_query(%{"filter" => ~s(title eq "#{title}")})

  test "fetch/1 looks the vault and the item up by name, then reads the item by its ID" do
    responses = %{
      "/v1/vaults" => [
        %{"id" => "another0vault0id0000000000", "name" => "staging"},
        %{"id" => @vault_id, "name" => "production"}
      ],
      item_filter("myphoenixapp") => [%{"id" => @item_id, "title" => "myphoenixapp"}],
      "/v1/vaults/#{@vault_id}/items/#{@item_id}" => @item
    }

    with_connect(responses, credentials(), fn ->
      assert Connect.fetch(@path) ==
               {:ok, %{"DATABASE_URL" => "ecto://db", "PHX_HOST" => "example.com"}}
    end)

    # The trailing slash of the host is dropped, and every request carries the token
    assert_received {:request, "/v1/vaults", headers}
    assert {"authorization", "Bearer connect-token"} in headers

    assert_received {:request,
                     "/v1/vaults/ftz4pm2xxwmwrsd7rjqn7grzfz/items?filter=title+eq+%22myphoenixapp%22",
                     _}
  end

  test "fetch/1 reads an item given by its ID directly" do
    responses = %{
      "/v1/vaults" => [%{"id" => @vault_id, "name" => "production"}],
      "/v1/vaults/#{@vault_id}/items/#{@item_id}" => @item
    }

    with_connect(responses, credentials(), fn ->
      assert {:ok, %{"DATABASE_URL" => "ecto://db"}} =
               Connect.fetch("vaults/production/items/#{@item_id}")
    end)
  end

  test "fetch/1 takes an item that looks like an ID as a title when no item has that ID" do
    title = "abcdefghijklmnopqrstuvwxyz"

    responses = %{
      "/v1/vaults" => [%{"id" => @vault_id, "name" => "production"}],
      "/v1/vaults/#{@vault_id}/items/#{title}" =>
        {404, ~s({"status":404,"message":"item not found"})},
      item_filter(title) => [%{"id" => @item_id, "title" => title}],
      "/v1/vaults/#{@vault_id}/items/#{@item_id}" => @item
    }

    with_connect(responses, credentials(), fn ->
      assert {:ok, %{"PHX_HOST" => "example.com"}} =
               Connect.fetch("vaults/production/items/#{title}")
    end)
  end

  test "fetch/1 takes a vault that no vault is named after as an ID" do
    responses = %{
      "/v1/vaults" => [%{"id" => "another0vault0id0000000000", "name" => "staging"}],
      item_filter("myphoenixapp") => [%{"id" => @item_id, "title" => "myphoenixapp"}],
      "/v1/vaults/#{@vault_id}/items/#{@item_id}" => @item
    }

    with_connect(responses, credentials(), fn ->
      assert {:ok, _fields} = Connect.fetch("vaults/#{@vault_id}/items/myphoenixapp")
    end)
  end

  test "fetch/1 uses the oldest of several items with the same title" do
    newer = "newer0item0id0000000000000"

    responses = %{
      "/v1/vaults" => [%{"id" => @vault_id, "name" => "production"}],
      item_filter("myphoenixapp") => [
        %{"id" => newer, "title" => "myphoenixapp", "createdAt" => "2026-05-01T10:00:00Z"},
        %{"id" => @item_id, "title" => "myphoenixapp", "createdAt" => "2025-01-01T10:00:00Z"}
      ],
      "/v1/vaults/#{@vault_id}/items/#{@item_id}" => @item
    }

    with_connect(responses, credentials(), fn ->
      assert {:ok, _fields} = Connect.fetch(@path)
    end)

    refute_received {:request,
                     "/v1/vaults/ftz4pm2xxwmwrsd7rjqn7grzfz/items/newer0item0id0000000000000", _}
  end

  test "fetch/1 returns no secrets for an item without fields" do
    responses = %{
      "/v1/vaults" => [%{"id" => @vault_id, "name" => "production"}],
      item_filter("myphoenixapp") => [%{"id" => @item_id, "title" => "myphoenixapp"}],
      "/v1/vaults/#{@vault_id}/items/#{@item_id}" => %{"id" => @item_id}
    }

    with_connect(responses, credentials(), fn ->
      assert Connect.fetch(@path) == {:ok, %{}}
    end)
  end

  test "fetch/1 says which vault or item was not found" do
    vaults = %{"/v1/vaults" => [%{"id" => @vault_id, "name" => "production"}]}

    with_connect(vaults, credentials(), fn ->
      assert Connect.fetch("vaults/missing/items/myphoenixapp") ==
               {:error, {:not_found, :vault, "missing"}}
    end)

    with_connect(Map.put(vaults, item_filter("missing"), []), credentials(), fn ->
      assert Connect.fetch("vaults/production/items/missing") ==
               {:error, {:not_found, :item, "missing"}}
    end)
  end

  test "fetch/1 reports the status of a refused request without its body" do
    responses = %{"/v1/vaults" => {401, ~s({"status":401,"message":"Invalid token signature"})}}

    with_connect(responses, credentials(), fn ->
      assert Connect.fetch(@path) == {:error, {:http_status, 401, "/v1/vaults"}}
    end)

    forbidden = %{
      "/v1/vaults" => [%{"id" => @vault_id, "name" => "production"}],
      item_filter("myphoenixapp") => {403, ~s({"status":403,"message":"vault is not in scope"})}
    }

    with_connect(forbidden, credentials(), fn ->
      # The query, which holds the title, is not part of the reason
      assert Connect.fetch(@path) ==
               {:error, {:http_status, 403, "/v1/vaults/#{@vault_id}/items"}}
    end)
  end

  test "fetch/1 reports a server that cannot be reached, or that does not answer in JSON" do
    with_connect(%{"/v1/vaults" => {:error, :econnrefused}}, credentials(), fn ->
      assert Connect.fetch(@path) == {:error, {:request_failed, :econnrefused}}
    end)

    with_connect(%{"/v1/vaults" => {200, "<html>proxy</html>"}}, credentials(), fn ->
      assert Connect.fetch(@path) == {:error, :invalid_json}
    end)

    with_connect(%{"/v1/vaults" => %{"not" => "a list"}}, credentials(), fn ->
      assert Connect.fetch(@path) == {:error, {:unexpected_response, :vault}}
    end)
  end

  test "fetch/1 makes no request without the server and its token, or with a bad path" do
    for env <- [
          %{},
          %{"OP_CONNECT_HOST" => @host},
          %{"OP_CONNECT_HOST" => "", "OP_CONNECT_TOKEN" => "t"}
        ] do
      with_connect(%{}, env, fn ->
        assert Connect.fetch(@path) ==
                 {:error, {:missing_env, ["OP_CONNECT_HOST", "OP_CONNECT_TOKEN"]}}
      end)
    end

    with_connect(%{}, credentials(), fn ->
      assert Connect.fetch("production/myphoenixapp") == {:error, :invalid_path}
    end)

    refute_received {:request, _path, _headers}
  end

  # The real pool and supervisor, against a port nothing listens on
  test "fetch/1 can be called by several processes at the same time" do
    previous = Map.new(~w(OP_CONNECT_HOST OP_CONNECT_TOKEN), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env("OP_CONNECT_HOST", "http://127.0.0.1:1")
    System.put_env("OP_CONNECT_TOKEN", "connect-token")

    results =
      1..20
      |> Task.async_stream(fn _n -> Connect.fetch(@path) end, max_concurrency: 20)
      |> Enum.to_list()

    assert length(results) == 20
    assert Enum.all?(results, &match?({:ok, {:error, {:request_failed, _reason}}}, &1))
  end
end
