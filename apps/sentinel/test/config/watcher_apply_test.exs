defmodule Sentinel.Config.WatcherApplyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mock

  alias Deployer.Engine
  alias Deployer.Engine.Supervisor, as: EngineSupervisor
  alias Deployer.Monitor
  alias Deployer.Monitor.Supervisor, as: MonitorSupervisor
  alias Foundation.Certificate
  alias Sentinel.Config.Upgradable
  alias Sentinel.Config.Watcher
  alias Sentinel.Fixture.Watcher, as: FixtureWatcher

  @default_upgradable %Upgradable{
    logs_retention_time_ms: 86_400_000,
    metrics_retention_time_ms: 86_400_000,
    monitoring: [],
    applications: [],
    config_checksum: "current_checksum"
  }

  test "broadcasts config change when applying" do
    with_mocks([
      {Upgradable, [], [from_app_env: fn -> @default_upgradable end]},
      {Engine, [], [init_worker: fn _application -> :ok end]},
      {EngineSupervisor, [], [stop_deployment: fn _name -> :ok end]},
      {Monitor, [], [init_monitor_supervisor: fn _name -> :ok end]},
      {MonitorSupervisor, [], [stop: fn _name -> :ok end]},
      {Certificate, [], [start_certificate_manager: fn _name, _certificates -> :ok end]},
      {Certificate, [], [stop_certificate_manager: fn _name -> :ok end]},
      {Engine.Worker, [], [updated_state_values: fn _name, _map_values -> :ok end]},
      {Sentinel.Watchdog, [], [reset_app_statistics: fn _name -> :ok end]},
      {Sentinel.Logs, [], [update_data_retention_period: fn _new_value -> :ok end]},
      {Application, [:passthrough], [put_all_env: fn _config_updates -> :ok end]}
    ]) do
      log =
        capture_log(fn ->
          {:ok, pid} = Watcher.start_link(name: :test_apply_broadcast)
          node = Node.self()

          # Subscribe to config changes
          Watcher.subscribe_apply_new_config()

          pending_changes = FixtureWatcher.build_pending_changes()

          # Set pending config
          :sys.replace_state(pid, fn state ->
            %{
              state
              | pending_config: %Upgradable{},
                pending_changes: pending_changes
            }
          end)

          assert :ok = Watcher.apply_changes(pid)

          # Verify broadcast received
          assert_receive {:watcher_config_apply, ^node, ^pending_changes}, 1000
        end)

      assert log =~ "ConfigWatcher: Removing application: myumbrella"
    end
  end

  test "applies a hot_upgrade_config_change change to the engine worker" do
    old_app = %Foundation.Yaml.Application{name: "myapp", hot_upgrade_config_change: true}
    new_app = %{old_app | hot_upgrade_config_change: false}

    pending_changes = %Sentinel.Config.Changes{
      summary: %{
        applications: %{
          old: [old_app],
          new: [new_app],
          details: %{
            "myapp" => %{
              status: :modified,
              changes: %{
                hot_upgrade_config_change: %{old: true, new: false, apply_strategy: :next_deploy}
              },
              apply_strategies: [:next_deploy]
            }
          }
        }
      },
      timestamp: DateTime.utc_now(),
      changes_count: 1
    }

    test_pid = self()

    with_mocks([
      {Upgradable, [], [from_app_env: fn -> @default_upgradable end]},
      {Engine.Worker, [],
       [
         updated_state_values: fn name, values ->
           send(test_pid, {:updated_state_values, name, values})
           :ok
         end
       ]},
      {Application, [:passthrough],
       [
         put_all_env: fn config_updates ->
           send(test_pid, {:put_all_env, config_updates})
           :ok
         end
       ]}
    ]) do
      capture_log(fn ->
        {:ok, pid} = Watcher.start_link(name: :test_apply_hot_upgrade_config_change)

        :sys.replace_state(pid, fn state ->
          %{state | pending_config: %Upgradable{}, pending_changes: pending_changes}
        end)

        assert :ok = Watcher.apply_changes(pid)
      end)

      # The worker reads it on its next hot upgrade
      assert_receive {:updated_state_values, "myapp", %{hot_upgrade_config_change: false}}, 1_000

      # And the stored applications hold it, for a worker that restarts
      assert_receive {:put_all_env, config_updates}, 1_000
      assert [%{hot_upgrade_config_change: false}] = config_updates[:foundation][:applications]
    end
  end
end
