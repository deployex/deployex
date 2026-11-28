defmodule Deployer.Status.DbTest do
  use ExUnit.Case, async: false

  import Mox

  alias Deployer.Status.Db

  setup [
    :set_mox_global,
    :verify_on_exit!
  ]

  @node :"myelixir-abc123@nohost"
  @app :myelixir
  @web_app :myelixir_web

  test "version/1 returns the Postgres server version through the app's own repo" do
    Foundation.RpcMock
    |> expect(:call, fn @node, :application, :which_applications, [], _timeout ->
      [{@app, "myelixir", "1.0.0"}]
    end)
    |> expect(:call, fn @node, Application, :get_env, [@app, :ecto_repos, []], _timeout ->
      [MyElixir.Repo]
    end)
    |> expect(:call, fn @node, MyElixir.Repo, :__adapter__, [], _timeout ->
      Ecto.Adapters.Postgres
    end)
    |> expect(:call, fn @node,
                        Ecto.Adapters.SQL,
                        :query,
                        [MyElixir.Repo, "SELECT version()", []],
                        _timeout ->
      {:ok,
       %{
         rows: [
           [
             "PostgreSQL 16.4 (Debian 16.4-1.pgdg120+1) on x86_64-pc-linux-gnu, compiled by gcc (Debian 12.2.0-14) 12.2.0, 64-bit"
           ]
         ]
       }}
    end)

    assert {:ok, "PostgreSQL 16.4"} = Db.version(@node)
  end

  test "version/1 recognizes CockroachDB behind the same Postgres adapter" do
    Foundation.RpcMock
    |> expect(:call, fn @node, :application, :which_applications, [], _timeout ->
      [{@app, "myelixir", "1.0.0"}]
    end)
    |> expect(:call, fn @node, Application, :get_env, [@app, :ecto_repos, []], _timeout ->
      [MyElixir.Repo]
    end)
    |> expect(:call, fn @node, MyElixir.Repo, :__adapter__, [], _timeout ->
      Ecto.Adapters.Postgres
    end)
    |> expect(:call, fn @node,
                        Ecto.Adapters.SQL,
                        :query,
                        [MyElixir.Repo, "SELECT version()", []],
                        _timeout ->
      {:ok,
       %{
         rows: [
           [
             "CockroachDB CCL v23.1.11 (x86_64-pc-linux-gnu, built 2023/08/14 18:42:21, go1.19.10)"
           ]
         ]
       }}
    end)

    assert {:ok, "CockroachDB 23.1.11"} = Db.version(@node)
  end

  test "version/1 returns the MySQL server version" do
    Foundation.RpcMock
    |> expect(:call, fn @node, :application, :which_applications, [], _timeout ->
      [{@app, "myelixir", "1.0.0"}]
    end)
    |> expect(:call, fn @node, Application, :get_env, [@app, :ecto_repos, []], _timeout ->
      [MyElixir.Repo]
    end)
    |> expect(:call, fn @node, MyElixir.Repo, :__adapter__, [], _timeout ->
      Ecto.Adapters.MyXQL
    end)
    |> expect(:call, fn @node,
                        Ecto.Adapters.SQL,
                        :query,
                        [MyElixir.Repo, "SELECT VERSION()", []],
                        _timeout ->
      {:ok, %{rows: [["8.0.36"]]}}
    end)

    assert {:ok, "MySQL 8.0.36"} = Db.version(@node)
  end

  test "version/1 finds the repo declared under an umbrella sibling app" do
    Foundation.RpcMock
    |> expect(:call, fn @node, :application, :which_applications, [], _timeout ->
      [{@app, "myelixir", "1.0.0"}, {@web_app, "myelixir_web", "1.0.0"}]
    end)
    |> expect(:call, fn @node, Application, :get_env, [@app, :ecto_repos, []], _timeout -> [] end)
    |> expect(:call, fn @node, Application, :get_env, [@web_app, :ecto_repos, []], _timeout ->
      [MyElixir.Repo]
    end)
    |> expect(:call, fn @node, MyElixir.Repo, :__adapter__, [], _timeout ->
      Ecto.Adapters.Postgres
    end)
    |> expect(:call, fn @node,
                        Ecto.Adapters.SQL,
                        :query,
                        [MyElixir.Repo, "SELECT version()", []],
                        _timeout ->
      {:ok, %{rows: [["PostgreSQL 16.4 on x86_64-pc-linux-gnu"]]}}
    end)

    assert {:ok, "PostgreSQL 16.4"} = Db.version(@node)
  end

  test "version/1 returns nil when no app declares ecto_repos" do
    Foundation.RpcMock
    |> expect(:call, fn @node, :application, :which_applications, [], _timeout ->
      [{@app, "myelixir", "1.0.0"}]
    end)
    |> expect(:call, fn @node, Application, :get_env, [@app, :ecto_repos, []], _timeout -> [] end)

    assert {:ok, nil} = Db.version(@node)
  end

  test "version/1 returns nil for an adapter it does not recognize" do
    Foundation.RpcMock
    |> expect(:call, fn @node, :application, :which_applications, [], _timeout ->
      [{@app, "myelixir", "1.0.0"}]
    end)
    |> expect(:call, fn @node, Application, :get_env, [@app, :ecto_repos, []], _timeout ->
      [MyElixir.Repo]
    end)
    |> expect(:call, fn @node, MyElixir.Repo, :__adapter__, [], _timeout ->
      Ecto.Adapters.SQLite3
    end)

    assert {:ok, nil} = Db.version(@node)
  end

  test "version/1 returns an error when the node is unreachable" do
    Foundation.RpcMock
    |> expect(:call, fn @node, :application, :which_applications, [], _timeout ->
      {:badrpc, :nodedown}
    end)

    assert {:error, nil} = Db.version(@node)
  end
end
