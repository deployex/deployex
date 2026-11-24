# 🔥 Hot-Upgrades

DeployEx applies hot upgrades to the applications it monitors and to itself, using [Jellyfish][jyf] to generate the appup files automatically.

**The BEAM mechanism itself (`appup`, `relup`, `release_handler`), the coding practices that make a project hot-upgradable, and framework-level pitfalls (Phoenix/LiveView, closures, supervision tree changes) are documented once, outside this project, in [beam-hotupgrades](https://github.com/deployex/beam-hotupgrades).** Read that first. This page only covers what DeployEx itself adds on top: how it resolves configuration during the upgrade, how it decides whether a package is applicable, and how to drive a hot upgrade of DeployEx or a monitored application.

## What DeployEx hot-upgrades

 * **Monitored applications** - your deployed Elixir/Erlang/Gleam applications.
 * **Dependencies** - DeployEx reports them separately, with `type: "dependency"` rather than `type: "project"`, see [beam-hotupgrades](https://github.com/deployex/beam-hotupgrades) for why dependencies are assessed individually.
 * **DeployEx itself** - without restarting the deployment system.

Erlang/OTP, Elixir version changes, and config provider changes are never hot-upgraded, see [When NOT to hot-upgrade](https://github.com/deployex/beam-hotupgrades#when-not-to-hot-upgrade) for why. Picking a release artifact built for another OTP line is the easiest way to hit this by accident, see [Choosing the right release file](#choosing-the-right-release-file) below.

### What happens to configuration during a hot-upgrade

`runtime.exs` and the Config Providers only run when an application boots, so DeployEx resolves them itself over the RPC channel and applies the result during the install.
Understanding the order matters, because it decides which of your configuration changes actually take effect.

`release_handler:install_release/2` first rebuilds the environment of **every** loaded application from the new `.app` files and the new build time `sys.config`, and only then runs the relup instructions.
DeployEx adds a hook at the head of that relup which applies the resolved configuration, so the environment is complete before any process is suspended or has its code changed.

What that means in practice:

 * **Changed or removed keys are applied.** The environment is deleted and rebuilt, not merged, so a key you delete in the new version is really gone after the upgrade.
 * **A changed `runtime.exs` is applied.** DeployEx reads the new version's file, which `unpack_release/1` has already written to disk, so the values the application ends up with are the ones the new file resolves. The one condition is that it runs on the node as it is now: it is evaluated by the code the running node has loaded, so it must not rely on modules, functions or language features that only arrive with the new release. A `runtime.exs` that reads environment variables, files or secrets is fine. One that calls into a module the new version introduces is not, and that is the case to deploy fully.
 * **`config_change/3` can be made to run on every hot upgrade.** OTP only calls it for an application whose environment changed, so a release can ask DeployEx to set one key of its own, see [Telling the application that it was hot-upgraded](#telling-the-application-that-it-was-hot-upgraded).
 * **A changed Config Provider is NOT applied.** Provider modules run on the node in its current version, before the new code is installed, so the old implementation is what resolves the configuration. A fix to a provider only takes effect once a full deployment has made it the running version.

### The version on traces and logs

An application reads its version once, when it boots, and two places keep the value they were given: the OpenTelemetry SDK holds the resource, with its `service.version`, in the state of its processes, and a `:logger` filter or formatter that stamps the version on every event holds it in its configuration.
A hot upgrade restarts neither, so without help the node runs the new code and keeps reporting the old version.

DeployEx adds a second instruction to the relup for this, at its end, once every process is running the new code again.
It replaces the value where it is held and restarts nothing, so the spans that are open and the events that are queued are kept:

 * **Traces**: the `service.version` of the resource, in the processes of the OpenTelemetry SDK 1.x that hold it. It is only replaced when it is exactly the version being upgraded from, so a `service.version` that is not the release version is left alone.
 * **Logs**: every value equal to the version being upgraded from, in the filters and the formatter of each `:logger` handler, and in the filters and the metadata of the primary configuration.

There is nothing to turn on, and nothing to add to the application: an application without OpenTelemetry, or whose logs carry no version, is not changed.
It runs for every hot upgrade, whether or not the release asks for `config_change/3`.

 * **It only knows the release version.** The version is matched as the text DeployEx deploys, `1.1.0` or `1.1.0-9cad9cd`. A version the application derives from something else, keeps as another type, or holds anywhere else (a metric tag, a `:persistent_term`, the state of one of its own processes) is not seen. That is what `config_change/3`, below, is for.
 * **It cannot fail the upgrade.** It runs after the point of no return, so every part of it catches its own errors, and a part that fails leaves the value as it was.
 * **An upgrade that restarts the VM does not carry it.** The node boots on the new version and reads it again.
 * **What it did is kept too.** The relup says what the node was told to do, not what came of it, so once the release is installed DeployEx asks the node and keeps the answer with the relup. The Versions page shows it under the outcome of the upgrade, and the Agent API returns it as `version_update`:

   | | |
   |---|---|
   | `Traces: service.version moved from 1.0.0 to 1.1.0` | The resource was replaced |
   | `Traces: left alone, service.version was 2024.11 and not 1.0.0` | The application reports something other than the release version, so it is for its `config_change/3` to update |
   | `Traces: the OpenTelemetry SDK is not running, nothing to change` | The application has no SDK |
   | `Traces: service.version could not be replaced in every process that holds it, the node may still report 1.0.0` | One of the processes of the SDK did not answer in time. The process that says which version the node reports is left as it was, so the next hot upgrade says `left alone` rather than claim a version that was not reached. A restart of the application brings it up to date |
   | `Logs: 1 logger setting moved to 1.1.0` | A filter, a formatter or the metadata held the version |
   | `Logs: no logger setting held 1.0.0, nothing changed` | The logs carry no version, or not the release version |

 * **It is in the relup DeployEx keeps**, as its last step, see [Seeing what a hot upgrade did](#seeing-what-a-hot-upgrade-did). The code it runs is `apps/deployer/priv/relup/version_update.erl` in the DeployEx repository, next to `runtime_config.erl`, the code of the hook that applies the configuration.

### Broadway pipelines

A hot upgrade removes the previous version of every module it loads, and a process that is still inside one is killed.
For a [Broadway](https://hexdocs.pm/broadway) pipeline that is a message half handled, and with a producer that waits for an acknowledgement, such as RabbitMQ, it is worse than a lost message.
Broadway starts the processor again and not the connection, so the message stays delivered and never acknowledged, and a consumer with a prefetch of 1 is sent nothing else until it is restarted.
Nothing is logged: the consumer looks connected and receives nothing.

So DeployEx keeps the pipelines out of the way while the code is replaced, with two more instructions in the relup:

 * **Right after the point of no return**, before any module is loaded, it stops each running pipeline through the supervisor that started it. That is Broadway's graceful shutdown: the messages being handled finish, and what does not finish in time goes back to its queue when the connection closes.
 * **At the end**, once every process runs the new code, it starts them again.

There is nothing to turn on, and nothing to add to the application.

 * **The upgrade waits for the messages in flight**, up to 30 seconds for all the pipelines together, which stop at the same time. Consumers that handle a message in milliseconds add nothing noticeable. A pipeline that is still stopping after 30 seconds is no longer waited for: the upgrade goes on, a message it is still handling can be killed as before, and it is started again at the end.
 * **Nothing is consumed on that node meanwhile.** The other nodes keep consuming.
 * **A pipeline DeployEx could not start again is left alone**: one that was not started under a name, or by a supervisor that keeps no child to start again, such as a `DynamicSupervisor`. So is an application without Broadway, or with a version of it that does not list its pipelines.
 * **An upgrade that restarts the VM does not carry them**, it stops everything anyway.
 * **It cannot fail the upgrade.** Both instructions catch their own errors, and what is to be started again is written down before anything is stopped.
 * **What happened is kept**, with the relup: each pipeline, whether it stopped in time and whether it started. The Versions page shows it under the outcome of the upgrade, and the Agent API returns it as `pipelines`. The code is `apps/deployer/priv/relup/pipelines_stop.erl` and `pipelines_start.erl`.

### Background jobs

A job that is running when a module it is inside of is replaced is killed too.
[Oban](https://hexdocs.pm/oban) treats that as any other failure: the job is recorded with `killed` as its error and tried again on the new code, so nothing is stuck. The job still loses an attempt and the work it had done.

When Oban shuts down it does better for the jobs that are almost done: it starts no new job and waits for the running ones, for its `shutdown_grace_period`.
DeployEx gives a hot upgrade the same, with two more instructions in the relup:

 * **Right after the point of no return**, it pauses the Oban queues of this node and waits for the running jobs, for the `shutdown_grace_period` of the instance: 15 seconds unless the application sets another, and 20 seconds at most.
 * **At the end**, it resumes them.

There is nothing to turn on, and nothing to add to the application.

 * **A job that outlasts the wait keeps running.** It is killed only when a module it is inside of is replaced by this upgrade, and Oban then tries it again, a few seconds later. A job whose code did not change is not touched, which a deployment that stops the node cannot offer.
 * **The rules for a job are the ones a deployment already asks for**: more than one attempt, since a kill uses one and a job with a single attempt is not tried again, and safe to run again from the start.
 * **Only this node is paused**, and no job starts on it during the upgrade. A queue that was already paused is left paused.
 * **The upgrade takes that much longer** when jobs are running, and no longer when the queues are idle. With the pipelines, an upgrade waits 50 seconds at most.
 * **An application without Oban is not changed**, nor is one with a version of it that cannot pause a queue on one node. An upgrade that restarts the VM does not carry the instructions.
 * **It cannot fail the upgrade.** Both instructions catch their own errors, and what is to be resumed is written down before the wait.
 * **What happened is kept**, with the relup: the queues that were paused, how many jobs were still running when the wait ended, and whether the queues were resumed. The Versions page shows it under the outcome of the upgrade, and the Agent API returns it as `jobs`. The code is `apps/deployer/priv/relup/jobs_pause.erl` and `jobs_resume.erl`.

### Telling the application that it was hot-upgraded

A hot upgrade replaces code without restarting anything, so nothing in the application runs again on its own: whatever it read or cached when it booted stays as it was.
OTP has a callback for this, `config_change/3` on the application callback module, but `release_handler` only calls it for an application whose environment is different after the upgrade.
A release that changes code and no configuration never triggers it.

A release can ask DeployEx to trigger it.
DeployEx then sets one key in the environment of the monitored application, as part of the configuration its relup hook applies:

```elixir
deployex_config_change: "1.1.0"   # the version being installed
```

The value is different on every upgrade, so `config_change/3` always runs.
It runs once the relup has finished, so the callback is already the new version's code and the environment it reads is the new one, `runtime.exs` included.

```elixir
@impl true
def config_change(changed, new, removed) do
  # :deployex_config_change is in `new` on the first hot upgrade after a boot
  # and in `changed` on the following ones
  ...
end
```

#### Turning it on

It is off unless the release asks for it, since it runs application code during the upgrade and only the application knows what its callback does.

The release asks for it in `current.json`, next to its version:

```json
{
  "version": "1.1.0",
  "hash": "9cad9cd3581c69fdd02ff60765e1c7dd4599d84a",
  "pre_commands": [],
  "hot_upgrade_config_change": true
}
```

 * `true` sets the key for this release. `false`, or leaving the field out, does not.
 * Anything other than `true` or `false` reads as the field being left out.
 * There is no host setting for it. The pipeline that writes `current.json` decides, release by release.

What each release asked for is stored with the version it deployed.
The Versions page of the application shows it in the `config_change` column as `requested`, `declined` or `not set`, and `GET /v1/apps/:name/versions` of the [Agent API](/guides/docs/agent-api/README.md) returns it as `hot_upgrade_config_change`, `null` when the release did not say.
A version deployed before this field existed shows as `not set`.

#### What to expect from it

 * The key is added to every application of the release that a `jellyfish.json` describes as `type: "project"`, which covers each application of an umbrella. A release without those files gets it on the application named after it.
 * Only an application that the running node has loaded gets the key. One that the new release adds has no environment to compare yet, and starts with the new code anyway.
 * The key is also set for Erlang and Gleam applications, as a binary.
 * It is only set by a hot upgrade. After a full deployment the key is absent until the next hot upgrade.
 * A release that does not ask, hot-upgraded over one that did, still gets the callback once. The key the earlier upgrade set is gone when the environment is rebuilt, so `config_change/3` is called with `:deployex_config_change` in `removed`. Look for the key in `changed` and `new`, as the Phoenix example below does, to react only to an upgrade that asked.
 * DeployEx logs which applications got the key, and logs a warning when a release asked and none did, which is the case when the release name is not an application of the node and no `jellyfish.json` of this version names one.
 * The callback runs inside `release_handler:install_release/2`, with the new code already running and before the release is made permanent, so the upgrade waits for it. Keep it short and hand anything slow to another process.
 * A callback that fails does not fail the upgrade. One that raises, exits or returns an error leaves the release installed and made permanent, and OTP does not log it, so have the callback report its own failures.

#### What the application does in it

A hot upgrade restarts nothing, so everything the application worked out when it booted is still what it worked out then.
DeployEx brings the version on traces and logs up to date itself, and `config_change/3` is where the application does the rest:

| What stays as it was | Why | What to do |
|---|---|---|
| The version the application reports | A value read at boot, such as an environment variable or `runtime.exs`, still holds the old one. `runtime.exs` is of no help either, it is evaluated before the new code is installed | Read `Application.spec(:my_app, :vsn)` when the callback runs. The value of `:deployex_config_change` is the same version |
| The version on traces (OpenTelemetry) and on log lines | The SDK keeps its resource in the state of its processes, and a logger filter, formatter or the metadata keeps the copy it was given at boot | Nothing: DeployEx replaces it in the relup, see [The version on traces and logs](#the-version-on-traces-and-logs). Only a version it cannot recognise, one that is not the release version or is kept somewhere else, is left to the application |
| The static asset manifest (Phoenix, digested assets) | The endpoint reads it when it starts | `MyAppWeb.Endpoint.config_change/2`, see [Phoenix applications](#phoenix-applications) |
| Pages that are already open (Phoenix) | A hot upgrade disconnects no one | Broadcast, and let the pages that subscribed decide what to show |
| A value a process took when it started | A database pool keeps the password it connected with, a client keeps the token it was built with | Restart that process. It applies to secrets too, see [Secrets from 1Password](/guides/docs/yaml/README.md#secrets-from-1password) |
| A cache filled at boot | Nothing ran again to fill it: an ETS table, a `:persistent_term`, a file read once | Fill it again |

Two rules follow from where the callback runs, which is inside the application controller of the node:

 * **It cannot stop or start an application, or change the application environment.** `Application.stop/1`, `Application.ensure_all_started/1` and `Application.put_env/3` are calls to the application controller, which is the process making them, so they exit with `calling_self`. OTP catches that exit and does not log it, and the upgrade goes on as if the work had been done. Reading is fine: `Application.get_env/2` and `Application.spec/2` return the new configuration and the new version.
 * **It has to return quickly.** While it runs, nothing else on the node can start or stop an application.

Most of the table needs neither: reading the version, asking another process to change its state and a broadcast are not calls to the application controller, and take a few milliseconds.
So the callback can do them itself:

```elixir
# lib/my_app/application.ex
@impl true
def config_change(changed, new, removed) do
  MyAppWeb.Endpoint.config_change(changed, removed)

  # In `new` on the first hot upgrade after a boot, in `changed` on the following ones
  if Keyword.has_key?(changed ++ new, :deployex_config_change) do
    version = :my_app |> Application.spec(:vsn) |> to_string()

    Phoenix.PubSub.broadcast(MyApp.PubSub, "hot_upgrade", {:hot_upgraded, version})
  end

  :ok
end
```

Work that does need the application controller is handed to another process: a `spawn/1`, a `Task`, or a process the application supervises.

#### Phoenix applications

**Keep the digested assets, and set `hot_upgrade_config_change` on every release.**
This is the recommended setup, and it is the one `mix phx.new` generates: `cache_static_manifest` stays in `config/prod.exs` and `mix assets.deploy` runs `phx.digest`.

`phx.digest` output is cached in memory when the endpoint starts, so on its own a hot upgrade leaves pages linking to the old digested file names, see [Phoenix and LiveView pitfalls](https://github.com/deployex/beam-hotupgrades#phoenix-and-liveview-pitfalls).
The `config_change/3` that `mix phx.new` generates calls `MyAppWeb.Endpoint.config_change/2`, and that function reloads the manifest every time it is called (checked with Phoenix 1.8):

```elixir
@impl true
def config_change(changed, _new, removed) do
  MyAppWeb.Endpoint.config_change(changed, removed)
  :ok
end
```

So the application needs no code change, and two things from its pipeline:

 * **`"hot_upgrade_config_change": true` in every `current.json`.** The manifest changes whenever an asset does, so this is a constant of the application rather than a choice per release. Without it, pages rendered after a hot upgrade link to file names the new release may not have, and load without their styles and scripts.
 * **Both versions built in the same directory.** `phx.digest` keeps the digested files it finds from earlier runs, so building the previous version and then the target, as a hot upgrade build already does for the appups, ships the old files in the new release. A page that was opened before the upgrade still requests them. A target built from a clean `priv/static` has only its own files, and those requests get a 404.

With both in place, a page rendered after the upgrade links to the new files, and a page that was already open keeps the consistent set it loaded.

Pages that are already open are not told that a new version is running: a hot upgrade does not disconnect anyone, so `Phoenix.LiveView.static_changed?/1` has no reconnect to report on.
Broadcast from the callback, or from the process it hands the work to, and let the LiveViews that subscribed decide what to show:

```elixir
@impl true
def config_change(changed, new, removed) do
  MyAppWeb.Endpoint.config_change(changed, removed)

  if Keyword.has_key?(changed ++ new, :deployex_config_change) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "hot_upgrade", :hot_upgraded)
  end

  :ok
end
```

**The alternative is stable file names, with no manifest.**
Leaving `cache_static_manifest` out of `config/prod.exs` keeps asset file names the same from one release to the next.
A hot upgrade then serves the new files under them as soon as it is installed, with nothing to reload and no flag to set, and a browser that revalidates a file gets the new one, since its `ETag` changed.
It cannot be misconfigured, and it costs three things:

 * A page that was already open gets the new files under the names it loaded, so it can end up running old markup and scripts against new styles.
 * Browsers revalidate each file on every load instead of caching it by its content hash.
 * `static_changed?/1` compares against the manifest, so without one it never reports a change, on a hot upgrade or a full deployment.

## The steps DeployEx runs over RPC on the running node

This follows the standard `release_handler` sequence described in [How a hot upgrade works](https://github.com/deployex/beam-hotupgrades#how-a-hot-upgrade-works), with DeployEx driving each step remotely:

1. `release_handler:unpack_release/1` registers the new release and puts its code on disk. Nothing is loaded yet.
2. `systools:make_relup/4` builds the plan. DeployEx inserts the resolved runtime configuration hook at its head, the pause of the Oban queues and the stop of the Broadway pipelines after its point of no return, and at its end the instruction that moves the version on traces and logs, the start of the pipelines and the resume of the queues.
3. `release_handler:check_install_release/1` evaluates the plan without applying it.
4. `release_handler:install_release/2` rebuilds the application environments and then runs the plan. From this point the node is running the new code.
5. `release_handler:make_permanent/1` makes the new version the one the node boots into next time.

Everything up to step 4 only writes files and computes, so a failure there leaves the node running exactly the code it had.
That distinction is what the failure messages report, and what decides whether DeployEx has anything to recover from.

After step 5, for a monitored app, DeployEx removes the release directories, `.rel` files and libraries of older versions from the app's release directory, and keeps the newest `releases_retention` releases that the app has installed (default 2, at least the current and previous ones).
It also unregisters the removed versions from `release_handler`.
DeployEx does not prune its own releases.

### Which version performs the upgrade

DeployEx unpacks the release, builds the relup and installs it using the version currently installed, and only afterwards is the new code in charge, see [Which version performs the upgrade](https://github.com/deployex/beam-hotupgrades#which-version-performs-the-upgrade) for the consequences of that.

Where it matters, a release's changelog says so under `Backwards incompatible changes`, and the answer there is to apply it as a full deployment once, after which hot upgrades carry on normally.

## Good practices and pitfalls

Coding practices that make a project hot-upgradable (closures, `code_change/3`, supervision tree changes, cross-version compatibility, native code) and framework-level pitfalls (Phoenix static assets, LiveView) are covered in [beam-hotupgrades](https://github.com/deployex/beam-hotupgrades#good-practices-for-a-project-that-can-be-hot-upgraded). They apply to any project DeployEx hot-upgrades, not just this one.

The one DeployEx-specific addition: exercising the upgrade before production belongs in CI. This project does that in [`hot_upgrade.yaml`](/.github/workflows/hot_upgrade.yaml): it checks out both tags, builds each, and publishes the target release with its hot-upgrade information as an artifact. It still does not apply the upgrade itself, that step is run by hand against a real node. The local guides walk through exactly that on a machine, see [Local-Elixir](/guides/docs/local-elixir/README.md). The [Calori project](https://github.com/thiagoesteves/calori/blob/main/.github/workflows/hot-upgrade.yaml) shows the same build-in-CI approach for a monitored application.

## Checking whether a hot upgrade is possible

See [Checking whether a hot upgrade is possible](https://github.com/deployex/beam-hotupgrades#checking-whether-a-hot-upgrade-is-possible) for the generic checks (toolchain comparison, package metadata, `release_handler:which_releases/0`). What follows is specific to DeployEx.

**Check the versions it claims to upgrade from.**
Extract a `jellyfish.json` and read its `from` and `to`.
For a `"project"` entry the `from` has to be the version currently running, which the Applications page shows, so a release built against an older version is not applicable no matter how well formed it is.
A `"dependency"` entry carries the library's own versions instead, since dependencies are versioned independently from the project.

**Let DeployEx answer for you.**
For a monitored application the decision is made at deployment time and written to the log:

```bash
[warning] HOT UPGRADE version DETECTED - [%Deployer.HotUpgrade.Jellyfish{name: "myphoenixapp",
type: "project", from: "1.0.0", to: "1.1.0"}]
```

```bash
[warning] HOT UPGRADE version NOT DETECTED, full deployment required, reason: :not_found
```

`:not_found` means no metadata was found in the package, and `:no_match_versions` means it was found but describes a different starting version.

For DeployEx itself, uploading the file on the Hot-Upgrade page validates it before anything is applied, and the release is only offered for `Apply` once it passes.
That check refuses a package built for another OTP, and the reasons it can report are described in [Choosing the right release file](#choosing-the-right-release-file).

**Ask the node what it has installed.**
`:release_handler.which_releases()` lists the releases the node knows about and their status, which tells you what a previous attempt left behind:

```elixir
iex> :release_handler.which_releases()
...> |> Enum.map(fn {_name, vsn, _apps, status} -> {vsn, status} end)
[{~c"1.1.0", :permanent}, {~c"1.0.0", :old}]
```

A version left as `unpacked` is one a previous attempt started and did not install.

## Hot-Upgrading DeployEx

To hot-upgrade DeployEx itself:

1. Check the [GitHub hot-upgrade workflow](/.github/workflows/hot_upgrade.yaml) for release creation
2. Review the Changelog to verify your current version supports upgrading to the target version

The DeployEx dashboard serves digested assets, as it recommends for [Phoenix applications](#phoenix-applications), and follows the same two rules.
DeployEx always forces `config_change/3` on itself during a self-upgrade, so the dashboard links to the new files as soon as the upgrade is installed, with nothing to set.
The hot-upgrade workflow builds the current and the target version in the same checkout, so its release file ships the digested files of both and a dashboard page that was already open keeps working.
A release file built from a clean checkout has only its own, so use the one that workflow produces for a hot upgrade.

Then choose one of the following methods:

### Method 1: Installer Script

Use the installer script with a local release file:
```bash
./deployex.sh --hot-upgrade --release-path /tmp/deployex-0.9.1.tar.gz

# Executing hot upgrade via RPC            #
# Release file: /tmp/hotupgrade/download/deployex-0.9.1.tar.gz

11:21:30.373 [info] deployex hot upgrade requested: 0.9.0 -> 0.9.1

11:21:42.745 [warning] Hot upgrade in deployex installed with success
# Hot upgrade completed successfully       #
```

### Method 2: UI Release Upload

Use the DeployEx web interface to upload a release file:

1. Open the Hot-Upgrade page in DeployEx
2. Upload the release file (DeployEx automatically validates it)
3. Click **Apply**, then confirm
4. Follow the steps on the page until the hot upgrade completes. The bell shows the progress on every page

### Method 3: GitHub Actions Release Download

Use the DeployEx web interface to download a release from GitHub:

1. Open the Hot-Upgrade page in DeployEx
2. Click **GitHub URL**
3. Enter the artifact URL
4. Enter your GitHub personal access token and click **Download** (DeployEx automatically validates the release)
5. Click **Apply**, then confirm
6. Follow the steps on the page until the hot upgrade completes. The bell shows the progress on every page

### Method 4: Terraform (IaC) self-upgrade

DeployEx can upgrade itself when Terraform publishes a new version. You bump one variable and apply. DeployEx does the rest.
This method is opt-in and disabled by default.

How it works:

1. Terraform writes `deployex_version` to the instance. On AWS it is an instance tag. On GCP it is an instance metadata attribute.
   A version bump updates the tag or attribute in place, so the instance is not replaced.
2. A reconciler in DeployEx (`Deployer.SelfUpgrade.Worker`) reads that desired version on a schedule.
3. When the desired version differs from the running version, DeployEx downloads the release and runs a hot upgrade of itself.

Enable it in config:

```elixir
config :deployer, Deployer.SelfUpgrade,
  enabled: true,
  interval_ms: 60_000,
  dist_base_url: nil

# Select the source that matches the cloud:
config :deployer, Deployer.SelfUpgrade.Source, adapter: Deployer.SelfUpgrade.Source.Aws
# or, on GCP:
# config :deployer, Deployer.SelfUpgrade.Source, adapter: Deployer.SelfUpgrade.Source.Gcp
```

`dist_base_url` is the base the DeployEx release is read from, with one path per version. Without it, the installer reads GitHub releases.
For a private bucket, set `s3://<bucket>/<prefix>`, see [AWS Hosts With No Internet Route](../aws-air-gapped/README.md).

The self-upgrade is hot-only: it tries a hot upgrade, and if the target is not hot-upgradeable, for example a new OTP line,
DeployEx stays on the current version and reports the failure. You then upgrade with one of the manual methods above. A restart
fallback would have to stop and re-lay-down `/opt/deployex`, which the unprivileged `deployex` service user cannot do safely, so it
is deliberately not offered here.

To roll out a new version: set `deployex_version` in Terraform, run `terraform apply`, then follow the self-upgrade on the
dashboard, in the bell and on the Hot Upgrade page, or in the DeployEx logs. The AWS instance must enable metadata tags
(`metadata_options { instance_metadata_tags = "enabled" }`), which the guide modules already set. The hot upgrade runs
`deployex rpc` against the running node; DeployEx passes the live distribution
cookie to that call automatically, so you do not need to set `RELEASE_COOKIE` for the worker.

On an instance provisioned before this feature, the on-disk `/home/root/deployex.sh` predates the `--set-version` flag the worker
passes, and cloud-init does not refresh it on a version bump. Refresh it once before enabling self-upgrade:
`wget -O /home/root/deployex.sh <dist_base_url>/<version>/deployex.sh && chmod +x /home/root/deployex.sh`. If the script is
outdated the worker reports it and does not attempt the upgrade, rather than latching a cryptic failure.

On an existing stack, the first `terraform apply` after you update to these guide modules replaces the instance once. The modules
now pass the cloud-init config as `user_data_base64` instead of `user_data`, and the config no longer holds the version, so the plan
shows `user_data` going to `null` and a new `user_data_base64`. After that, a version bump changes only the tag.

A failed version is latched: the worker does not retry it until the running version changes. This prevents a bad
version from looping. After you fix the cause, retry the same version in one of two ways:

- Restart DeployEx. The worker clears its state and reconciles again on the next tick.
- Run a forced reconcile as the `deployex` user, with `RELEASE_COOKIE` set to the live cookie:
  `RELEASE_COOKIE=<cookie> bin/deployex rpc "Deployer.SelfUpgrade.Worker.reconcile(force: true)"`. Without `force: true`
  the call returns `:noop` for the latched version.

### Choosing the right release file

Each release publishes one artifact per OTP line and CPU, `deployex-ubuntu-24.04-otp-28.tar.gz` and `deployex-ubuntu-24.04-otp-29.tar.gz`.
An arm64 host takes the same files with `-arm64` after the OS, such as `deployex-ubuntu-24.04-arm64-otp-28.tar.gz`.
The validation below checks the OTP, not the CPU, so take the file for the host CPU.
The file has to match the `otp_version` the installation runs, which is the one in its `deployex.yaml`.
Picking the wrong one is the easiest way to hit the first entry of [When NOT to hot-upgrade](https://github.com/deployex/beam-hotupgrades#when-not-to-hot-upgrade), updating Erlang OTP, without meaning to.

A hot upgrade replaces application code inside the running VM, it cannot replace the VM or the language runtime underneath it.
A release built for another OTP brings a different Erlang and Elixir, and `systools:make_relup/4` needs an `.appup` for every application whose version changes, which neither ships.

The wrong file is refused while the release is validated, before anything is unpacked, naming the OTP the installation runs:

```bash
[error] Hot upgrade refused, this release was built for a different OTP. deployex runs
OTP 28 with erts 16.4.0.6 and the release brings erts 17.0.6. A hot upgrade cannot
replace the runtime under a running system. Use the artifact matching the otp_version
this installation runs, or apply it as a full deployment.
```

### When a DeployEx upgrade fails

DeployEx does not fall back to a full deployment for itself.
It keeps running and logs why the upgrade stopped:

```bash
[error] Hot upgrade in deployex failed, 0.9.0 -> 0.9.1, reason: :make_relup.
Nothing was installed, deployex is still running 0.9.0.
```

The reason `systools` reports is included in that message, and the release unpacked by the attempt is unregistered, so the same version can be applied again once the cause is fixed.

Everything up to installing the release only writes files and builds the relup, so a failure there leaves the node running exactly the code it had, which is what `Nothing was installed` reports.
Past that point the new code is already loaded, and the message says so instead.

> [!NOTE]
> The UI applies the upgrade asynchronously, so the log records that it started and the outcome follows on a later line.
> The Hot Upgrade page shows each step as it happens, whatever started the upgrade.
> The installer script applies it synchronously, so there `Hot upgrade in deployex installed with success` is written once the upgrade has actually finished.

## Hot-Upgrading Monitored Applications

Example GitHub CI workflow for hot-upgrading applications:

1. Fetch `current.json` to identify deployed version
2. Checkout current version and compile
3. Checkout target version and compile
4. Generate release with hot-upgrade information

See [example workflow](https://github.com/thiagoesteves/calori/blob/main/.github/workflows/hot-upgrade.yaml) for implementation details.

Two things about the rollout are worth knowing before you rely on it.

**Migrations run before the upgrade, from the new version.**
The pre-commands declared in `current.json` are executed against the release that was just unpacked, before any code is installed, which is what lets a schema change and the code that needs it ship together without downtime.
The consequence is the ordinary one for online migrations: while they run, the code serving traffic is still the old version, so the migration has to be one the old code survives.
If a pre-command fails, or does not finish within `deploy_rollback_timeout_ms` of the moment the pre-commands start (DeployEx then stops it), the release is not installed on that instance: the version is ghosted and the instance keeps running the version it has.
If the pre-commands cannot start within that time, the application does not run again after them, or its monitor exits, nothing says the release is bad, so DeployEx deploys it fully instead. A full deployment runs the pre-commands, which may already have run, so they have to be safe to run twice.
Replicas that were upgraded before it stay on the new version.
A migration that can run longer than that needs a larger `deploy_rollback_timeout_ms`.
A monitored application that has crashed twice in a row since it last ran does not wait for `deploy_rollback_timeout_ms`.
DeployEx deploys the release fully at once.

**Replicas are upgraded one at a time.**
Each deployment cycle upgrades a single instance and then moves to the next, so a release is rolled across the replicas rather than applied to all of them at once.
During that window some replicas run the new version and some the old, which is the boundary compatibility rule from the good practices above.

### When a monitored application upgrade fails

A release only reaches the hot upgrade path when it shipped the `.appup` or `jellyfish.json` files saying it supports one.
What DeployEx does when that upgrade fails depends on whether the running node was already changed.

If it failed before the release was installed, nothing on the node was touched, so there is nothing to recover and no reason to restart it.
The version is ghosted and the application carries on serving what it already runs:

```bash
[error] Hot upgrade failed before the release was installed at sname: myphoenixapp-63wu32,
reason: :make_relup. myphoenixapp is still running 1.0.0, ghosting version 1.1.0.
```

A ghosted version is skipped by every following deployment, so the same broken release is not attempted again.
Publish a new version once the cause is fixed, the application is not stuck waiting for it.

A version is also ghosted when a full deployment does not report running within `deploy_rollback_timeout_ms`.
Either way, the ghosted version is stored on the host that ghosted it.
Other hosts, and new hosts that a scale-out adds, still deploy it while `current.json` points to it.
On the host that ghosted it, an instance that already runs the ghosted version goes back to the newest version that another instance runs.
DeployEx sends `deployment_rollback` when that deployment starts.
That deployment is not ghosted when it fails its own rollback window, also after a DeployEx restart, so the instance tries it again.
Each failed try sends `deployment_complete` with status `:error`.
After a ghost, point `current.json` to a good version.
The `version_ghosted` notification tells the pipeline that writes `current.json` when to do it.
The `pre_command_failed` notification reports a failing pre-command before that.
Retries report each failing pre-command once, until the pre-commands pass.
An autoscaler must not replace a host only because its monitored application is down, the new host deploys the same version.
Base the host health check on DeployEx, not on the monitored application.

If the node could not be reached, was stopping, or did not answer in time, nothing says the release is bad, so DeployEx deploys it fully instead of ghosting it.
A monitored application in a crash loop then still gets the release that fixes it.

The application card on the Applications page shows the last ghosted version, and `View all` opens the full list.
From there a single version or all of them can be removed, which makes the engine offer them again on its next check.
That is the way to retry a version that was ghosted for a reason that no longer applies.

If the release was already installed and a later step failed, the node is running code that was never made permanent.
There DeployEx does fall back to a full deployment, which restarts the instance on the new version:

```bash
[error] Hot Upgrade failed, running for full deployment
```

### Seeing what a hot upgrade did

The relup is the plan the node ran: which applications had their code replaced, which modules were loaded, which processes were suspended for a `code_change`, and which functions the upgrade called.
It is written into the release directory, which DeployEx removes when it prunes older releases, so DeployEx keeps a copy with the version history.

 * It is kept just before the release is installed, with the instructions DeployEx adds, the runtime configuration, the version on traces and logs, the stop and start of the Broadway pipelines and the pause and resume of the Oban queues, so it is what the node was given. An upgrade that failed after that point has its relup too.
 * Only the upgrade is kept. A relup also describes the way back, which DeployEx never applies.
 * It holds instructions, not configuration. The resolved configuration travels separately and is erased once the upgrade has applied it.
 * The newest 20 are kept for each application, one for each pair of versions.

On the Versions page of the application, a hot upgrade has a `relup` link. It opens under the row, with two views:

 * **Steps** lists what the node ran, in the order it ran it: each instruction, such as `suspend`, `load`, `code_change` or `purge`, with the modules it acted on and a sentence on what it means. The two purge options of a `load` are spelled out: they do not restart anything, a process runs the new code from its next call into the module, and they only decide what happens to one that is still inside older code. The `load` of each module of an application reads as one step. Under the steps, the outcome sums the upgrade up.
 * **Original file** shows the relup as text, with a button that copies it.

`GET /v1/apps/:name/relups/:from_version/:to_version` of the [Agent API](/guides/docs/agent-api/README.md) returns the same: the `steps`, each with its `meaning`, the `summary` and the script. Each version in `/versions` and `/ghosted` has the `from_version` that goes in that path.
The steps are the place to check that an appup edited by hand did what was meant, for instance that the `apply` restarting a child is there, and where it runs.

The relups of DeployEx's own hot upgrades are kept the same way.
DeployEx is not one of the monitored applications, so the Agent API has them under the node: `GET /v1/node/versions` lists the hot upgrades DeployEx applied to itself and `GET /v1/node/relups/:from_version/:to_version` returns the relup of one.
The dashboard does not show them yet.
The upgrade into the first version that keeps relups has none: it is run by the version that was installed, which did not keep them.

## Going back

There is no hot downgrade.
A relup can describe the way back, but DeployEx does not generate or apply one, and a release that turns out to be wrong is undone the same way any other bad release is: publish the previous version and let it deploy fully.

That is worth knowing while deciding, because it makes the two directions asymmetric.
The upgrade avoids downtime, the way back does not.
The more of your release that is state living inside processes, the more that asymmetry should push you towards being conservative about what goes into a hot upgrade at all.

## Glossary

The general `appup`/`relup`/`release_handler` terms are in [beam-hotupgrades' glossary](https://github.com/deployex/beam-hotupgrades#glossary). The one below is specific to DeployEx.

| Term | What it is |
| --- | --- |
| ghosted version | A version DeployEx has marked as not to be deployed again after it failed, skipped by later deployment checks until it is removed. |

## Additional Resources

- [beam-hotupgrades](https://github.com/deployex/beam-hotupgrades) - the BEAM hot upgrade mechanism, good practices, and pitfalls, not specific to DeployEx
- [Jellyfish Documentation][jyf] - AppUp file generation
- [Calori Project](https://github.com/thiagoesteves/calori) - Real-world implementation examples

[jyf]: https://github.com/deployex/jellyfish
