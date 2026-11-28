# CHANGELOG (1.0.X)

## 1.0.0 ()

### Backwards incompatible changes from 0.10.0

#### Hotupgrade
 * [`PULL-337`](https://github.com/deployex/deployex/pull/337) Apply this release as a full deployment, do not hot-upgrade from `0.10.0`. Bumping Erlang or Elixir is a full deployment, not a hot upgrade, and this release moves the toolchain to `28.5.0.8` with Elixir `1.19.7`, and to `29.1.2` with Elixir `1.20.5`. The config providers also changed, and they run on the node in its current version.

#### Installer Actions
 1. [`PULL-336`](https://github.com/deployex/deployex/pull/336) The repository moved to the `deployex` organization, and `deployex.sh` downloads the releases from there by default. It also installs from a private S3 bucket ([`PULL-331`](https://github.com/deployex/deployex/pull/331)) and on arm64 hosts ([`PULL-334`](https://github.com/deployex/deployex/pull/334)). Update the script before installing this release:
 ```bash
 rm deployex.sh
 wget https://github.com/deployex/deployex/releases/download/1.0.0/deployex.sh
 chmod a+x deployex.sh
 ./deployex.sh --install
 ```

#### Monitored applications
 * [`PULL-354`](https://github.com/deployex/deployex/pull/354) An application with no `readiness` section in `deployex.yaml` is now ready when its node answers over OTP distribution that it booted, and no longer when its OS process stayed up for `min_ready_ms`. Add `readiness` with `type: "timeout"` to keep the previous behavior.
 * [`PULL-365`](https://github.com/deployex/deployex/pull/365) The hot upgrade of an Erlang application is detected from the `jellyfish.json` of its release, as for Elixir. Build the release with [rebar3_jellyfish_plugin](https://github.com/deployex/rebar3_jellyfish_plugin), a release built with `rebar3_appup_plugin` is deployed in full.
 * [`PULL-388`](https://github.com/deployex/deployex/pull/388) An application that stops by itself with no error is started again. Before, one that ended with exit code 0 stayed down.
 * [`PULL-402`](https://github.com/deployex/deployex/pull/402) An application that is stopped gets `shutdown_timeout_ms` to stop by itself, 5 seconds by default, before it is killed. Set it to `0` to kill it at once, as before.

### Bug fixes
 * [`PULL-310`](https://github.com/deployex/deployex/pull/310) Show normalized CPU percentage in the system bar
 * [`PULL-312`](https://github.com/deployex/deployex/pull/312) Bump mint to 1.10.1 (CVE-2026-82672)
 * [`PULL-313`](https://github.com/deployex/deployex/pull/313) Make the log panel readable in dark mode
 * [`PULL-315`](https://github.com/deployex/deployex/pull/315) Set RELEASE_COOKIE for elixir apps
 * [`PULL-318`](https://github.com/deployex/deployex/pull/318) Ghost a hot upgrade whose pre_command fails, run it without blocking
 * [`PULL-319`](https://github.com/deployex/deployex/pull/319) Quote app env values and the DeployEx cookie in shell commands
 * [`PULL-320`](https://github.com/deployex/deployex/pull/320) Report a node that cannot be reached instead of crashing
 * [`PULL-321`](https://github.com/deployex/deployex/pull/321) Keep a running app up after an engine worker restart
 * [`PULL-322`](https://github.com/deployex/deployex/pull/322) Keep the monitored app on restart after a rollback
 * [`PULL-323`](https://github.com/deployex/deployex/pull/323) Keep DeployEx's variables out of the monitored app's environment
 * [`PULL-325`](https://github.com/deployex/deployex/pull/325) Paste once and give the IEx terminal a fixed PTY size
 * [`PULL-326`](https://github.com/deployex/deployex/pull/326) Deploy fully when a crash-looping app blocks a hot upgrade
 * [`PULL-327`](https://github.com/deployex/deployex/pull/327) Keep the previous version through a restarted rollback window
 * [`PULL-328`](https://github.com/deployex/deployex/pull/328) Keep the rollback window through restarts and replica changes
 * [`PULL-336`](https://github.com/deployex/deployex/pull/336) Move repository URLs to the deployex org
 * [`PULL-340`](https://github.com/deployex/deployex/pull/340) Bring every instance to the target version
 * [`PULL-342`](https://github.com/deployex/deployex/pull/342) Correct hot-upgrade CI coverage and Jellyfish output claims
 * [`PULL-368`](https://github.com/deployex/deployex/pull/368) Fix hex audit: bump idna to 8.0.0
 * [`PULL-370`](https://github.com/deployex/deployex/pull/370) Fix hex audit: bump phoenix to 1.8.17, phoenix_live_view to 1.2.15
 * [`PULL-380`](https://github.com/deployex/deployex/pull/380) Load the consolidated protocols of the release
 * [`PULL-381`](https://github.com/deployex/deployex/pull/381) Show only the urls an instance listens on, and ease the local setup
 * [`PULL-382`](https://github.com/deployex/deployex/pull/382) Read the development sign-in credentials at compile time
 * [`PULL-387`](https://github.com/deployex/deployex/pull/387) Ignore the jellyfish.json of another upgrade when checking a release
 * [`PULL-388`](https://github.com/deployex/deployex/pull/388) Start again an application that stopped by itself with no error
 * [`PULL-389`](https://github.com/deployex/deployex/pull/389) Deploy in full a release that brings another runtime
 * [`PULL-393`](https://github.com/deployex/deployex/pull/393) Cap the limit of open files of an application at one million
 * [`PULL-397`](https://github.com/deployex/deployex/pull/397) Send a notification once when DeployEx nodes are connected
 * [`PULL-406`](https://github.com/deployex/deployex/pull/406) Flaky lock_test.exs and logs server_test.exs assertions

### Enhancements
 * [`PULL-311`](https://github.com/deployex/deployex/pull/311) Label anonymous processes and LiveViews with Process.set_label/1
 * [`PULL-314`](https://github.com/deployex/deployex/pull/314) GitHub SSO via assent, with email allowlist
 * [`PULL-316`](https://github.com/deployex/deployex/pull/316) Support running behind a TLS-terminating proxy
 * [`PULL-317`](https://github.com/deployex/deployex/pull/317) Terraform-driven DeployEx self-upgrade (in-place)
 * [`PULL-324`](https://github.com/deployex/deployex/pull/324) Prune old releases with a configurable retention
 * [`PULL-329`](https://github.com/deployex/deployex/pull/329) Send pre_command_failed and version_ghosted events
 * [`PULL-330`](https://github.com/deployex/deployex/pull/330) Make the auth config upgradable at runtime
 * [`PULL-331`](https://github.com/deployex/deployex/pull/331) Install and upgrade DeployEx from a private S3 bucket
 * [`PULL-332`](https://github.com/deployex/deployex/pull/332) Read-only HTTP and stream API on its own port
 * [`PULL-333`](https://github.com/deployex/deployex/pull/333) Add the operate scope to restart, clear ghosts and set the mode
 * [`PULL-334`](https://github.com/deployex/deployex/pull/334) Build and publish arm64 releases
 * [`PULL-335`](https://github.com/deployex/deployex/pull/335) Serve log history and live log streams
 * [`PULL-337`](https://github.com/deployex/deployex/pull/337) Update dependencies and the OTP/Elixir toolchain
 * [`PULL-338`](https://github.com/deployex/deployex/pull/338) Refresh the dashboard
 * [`PULL-339`](https://github.com/deployex/deployex/pull/339) Run mix hex.audit in the static analysis job
 * [`PULL-343`](https://github.com/deployex/deployex/pull/343) Add configurable application readiness
 * [`PULL-352`](https://github.com/deployex/deployex/pull/352) Show the self-upgrade progress on the page and in the bell
 * [`PULL-353`](https://github.com/deployex/deployex/pull/353) Bump dependencies, add Dependabot
 * [`PULL-354`](https://github.com/deployex/deployex/pull/354) Default application readiness to otp
 * [`PULL-355`](https://github.com/deployex/deployex/pull/355) Bump actions/upload-artifact from 4 to 7
 * [`PULL-356`](https://github.com/deployex/deployex/pull/356) Bump actions/cache from 4 to 6
 * [`PULL-357`](https://github.com/deployex/deployex/pull/357) Bump actions/download-artifact from 4 to 8
 * [`PULL-358`](https://github.com/deployex/deployex/pull/358) Add HTTP readiness probe
 * [`PULL-359`](https://github.com/deployex/deployex/pull/359) Add custom function readiness probe over OTP
 * [`PULL-360`](https://github.com/deployex/deployex/pull/360) Add otp and http liveness probes for monitored applications
 * [`PULL-361`](https://github.com/deployex/deployex/pull/361) Show readiness and liveness status on the dashboard
 * [`PULL-363`](https://github.com/deployex/deployex/pull/363) Bump plug to fix a multipart parsing advisory
 * [`PULL-364`](https://github.com/deployex/deployex/pull/364) Drop dead phx.digest step from assets.deploy
 * [`PULL-365`](https://github.com/deployex/deployex/pull/365) Unify Erlang/Elixir hot-upgrade detection on jellyfish.json
 * [`PULL-366`](https://github.com/deployex/deployex/pull/366) Migrate generic hot-upgrade reference to beam-hotupgrades
 * [`PULL-367`](https://github.com/deployex/deployex/pull/367) Fix monitored-app env.sh.eex snippets in local-elixir* guides
 * [`PULL-371`](https://github.com/deployex/deployex/pull/371) Let a release ask for config_change/3 after a hot upgrade
 * [`PULL-372`](https://github.com/deployex/deployex/pull/372) Serve digested assets and reload them on self-upgrade
 * [`PULL-373`](https://github.com/deployex/deployex/pull/373) Read secrets from 1Password for DeployEx and monitored apps
 * [`PULL-374`](https://github.com/deployex/deployex/pull/374) Keep the relup of a hot upgrade with the version history
 * [`PULL-375`](https://github.com/deployex/deployex/pull/375) Refresh the secrets of an application on a hot upgrade
 * [`PULL-377`](https://github.com/deployex/deployex/pull/377) Move the version on traces and logs in the relup
 * [`PULL-378`](https://github.com/deployex/deployex/pull/378) Keep Broadway pipelines and Oban jobs out of the way while the code is replaced
 * [`PULL-379`](https://github.com/deployex/deployex/pull/379) Update ex_aws and ex_aws_s3 for their security advisories
 * [`PULL-383`](https://github.com/deployex/deployex/pull/383) Say who DeployEx is for, and that a hot upgrade is a choice
 * [`PULL-384`](https://github.com/deployex/deployex/pull/384) Say what each release cadence gets from DeployEx
 * [`PULL-385`](https://github.com/deployex/deployex/pull/385) Describe the Erlang flow without the plugin it no longer uses
 * [`PULL-386`](https://github.com/deployex/deployex/pull/386) What a hot upgrade leaves to the application
 * [`PULL-390`](https://github.com/deployex/deployex/pull/390) Build the Erlang release of the local guide in prod mode
 * [`PULL-391`](https://github.com/deployex/deployex/pull/391) Report a pipeline that could not be started after a hot upgrade
 * [`PULL-392`](https://github.com/deployex/deployex/pull/392) A trial of DeployEx in a container and as a Kubernetes pod, with nginx in front
 * [`PULL-395`](https://github.com/deployex/deployex/pull/395) Write the logs of DeployEx as JSON, as an option
 * [`PULL-396`](https://github.com/deployex/deployex/pull/396) HAProxy in front of the application in the container trial, in place of nginx
 * [`PULL-398`](https://github.com/deployex/deployex/pull/398) Find the other DeployEx nodes with a DNS query and connect to them
 * [`PULL-399`](https://github.com/deployex/deployex/pull/399) Deploy an application on one DeployEx node at a time
 * [`PULL-400`](https://github.com/deployex/deployex/pull/400) A Fleet page with the connected DeployEx nodes, their versions and deployment locks
 * [`PULL-401`](https://github.com/deployex/deployex/pull/401) Long node names for DeployEx and its applications, as an option
 * [`PULL-402`](https://github.com/deployex/deployex/pull/402) Give an application time to stop before it is killed
 * [`PULL-403`](https://github.com/deployex/deployex/pull/403) Admin and read-only access to the dashboard
 * [`PULL-404`](https://github.com/deployex/deployex/pull/404) Sign in with the identity of Cloudflare Access
 * [`PULL-405`](https://github.com/deployex/deployex/pull/405) Apply a change of the YAML as soon as it is seen, as an option
 * [`PULL-425`](https://github.com/deployex/deployex/pull/425) Publish a multi-arch DeployEx image to ghcr.io alongside the host binaries

# Host Binaries Available

This release includes binaries for the following Ubuntu versions:

 * Ubuntu 24.04 with OTP 28 - [deployex-ubuntu-24.04-otp-28.tar.gz](https://github.com/deployex/deployex/tree/main/devops/releases/otp-28/.tool-versions)
 * Ubuntu 24.04 with OTP 29 - [deployex-ubuntu-24.04-otp-29.tar.gz](https://github.com/deployex/deployex/tree/main/devops/releases/otp-29/.tool-versions)
 * Ubuntu 24.04 arm64 with OTP 28 - [deployex-ubuntu-24.04-arm64-otp-28.tar.gz](https://github.com/deployex/deployex/tree/main/devops/releases/otp-28/.tool-versions)
 * Ubuntu 24.04 arm64 with OTP 29 - [deployex-ubuntu-24.04-arm64-otp-29.tar.gz](https://github.com/deployex/deployex/tree/main/devops/releases/otp-29/.tool-versions)

 You can use these pre-built binaries, or you can build your own if preferred.

# Container Image

A multi-arch (amd64/arm64) image is also published to [`ghcr.io/deployex/deployex`](https://github.com/deployex/deployex/pkgs/container/deployex), tagged with this version and with `latest`.
The [Helm chart](https://github.com/deployex/deployex/tree/main/charts/deployex) uses it by default.

# Previous Releases

 * [0.10.0 🚀 (2026-09-08)](https://github.com/deployex/deployex/blob/0.10.0/CHANGELOG.md)
 * [0.9.14 🚀 (2026-09-08)](https://github.com/thiagoesteves/deployex/blob/0.9.14/CHANGELOG.md)
 * [0.9.13 🚀 (2026-08-14)](https://github.com/thiagoesteves/deployex/blob/0.9.13/CHANGELOG.md)
 * [0.9.12 🚀 (2026-08-12)](https://github.com/thiagoesteves/deployex/blob/0.9.12/CHANGELOG.md)
 * [0.9.11 🚀 (2026-08-12)](https://github.com/thiagoesteves/deployex/blob/0.9.11/CHANGELOG.md)
 * [0.9.10 🚀 (2026-08-10)](https://github.com/thiagoesteves/deployex/blob/0.9.10/CHANGELOG.md)
 * [0.9.9 🚀 (2026-08-07)](https://github.com/thiagoesteves/deployex/blob/0.9.9/CHANGELOG.md)
 * [0.9.8 🚀 (2026-08-06)](https://github.com/thiagoesteves/deployex/blob/0.9.8/CHANGELOG.md)
 * [0.9.7 🚀 (2026-07-21)](https://github.com/thiagoesteves/deployex/blob/0.9.7/CHANGELOG.md)
 * [0.9.6 🚀 (2026-07-14)](https://github.com/thiagoesteves/deployex/blob/0.9.6/CHANGELOG.md)
 * [0.9.5 🚀 (2026-07-08)](https://github.com/thiagoesteves/deployex/blob/0.9.5/CHANGELOG.md)
 * [0.9.4 🚀 (2026-06-22)](https://github.com/thiagoesteves/deployex/blob/0.9.4/CHANGELOG.md)
 * [0.9.3 🚀 (2026-06-17)](https://github.com/thiagoesteves/deployex/blob/0.9.3/CHANGELOG.md)
 * [0.9.2 🚀 (2026-06-15)](https://github.com/thiagoesteves/deployex/blob/0.9.2/CHANGELOG.md)
 * [0.9.1 🚀 (2026-05-15)](https://github.com/thiagoesteves/deployex/blob/0.9.1/CHANGELOG.md)
 * [0.9.0 🚀 (2026-04-01)](https://github.com/thiagoesteves/deployex/blob/0.9.0/CHANGELOG.md)
 * [0.8.0 🚀 (2025-11-20)](https://github.com/thiagoesteves/deployex/blob/0.8.0/CHANGELOG.md)
 * [0.7.3 🚀 (2025-10-28)](https://github.com/thiagoesteves/deployex/blob/0.7.3/CHANGELOG.md)
 * [0.7.2 🚀 (2025-10-16)](https://github.com/thiagoesteves/deployex/blob/0.7.2/CHANGELOG.md)
 * [0.7.1 🚀 (2025-10-15)](https://github.com/thiagoesteves/deployex/blob/0.7.1/CHANGELOG.md)
 * [0.7.0 🚀 (2025-10-07)](https://github.com/thiagoesteves/deployex/blob/0.7.0/CHANGELOG.md)
 * [0.6.1 🚀 (2025-08-29)](https://github.com/thiagoesteves/deployex/blob/0.6.1/CHANGELOG.md)
 * [0.6.0 🚀 (2025-08-22)](https://github.com/thiagoesteves/deployex/blob/0.6.0/CHANGELOG.md)
 * [0.5.2 🚀 (2025-06-13)](https://github.com/thiagoesteves/deployex/blob/0.5.2/CHANGELOG.md)
 * [0.5.1 🚀 (2025-06-03)](https://github.com/thiagoesteves/deployex/blob/0.5.1/CHANGELOG.md)
 * [0.5.0 🚀 (2025-05-27)](https://github.com/thiagoesteves/deployex/blob/0.5.0/CHANGELOG.md)
 * [0.4.2 🚀 (2025-05-13)](https://github.com/thiagoesteves/deployex/blob/0.4.2/CHANGELOG.md)
 * [0.4.1 🚀 (2025-04-25)](https://github.com/thiagoesteves/deployex/blob/0.4.1/CHANGELOG.md)
 * [0.4.0 🚀 (2025-04-23)](https://github.com/thiagoesteves/deployex/blob/0.4.0/CHANGELOG.md)
 * [0.3.4 🚀 (2025-04-14)](https://github.com/thiagoesteves/deployex/blob/0.3.4/CHANGELOG.md)
 * [0.2.0 🚀 (2024-05-23)](https://github.com/thiagoesteves/deployex/blob/0.2.0/CHANGELOG.md)
 * [0.1.0 🚀 (2024-05-06)](https://github.com/thiagoesteves/deployex/blob/0.1.0/changelog.md)