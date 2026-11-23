# YAML Configuration and Management

## Overview

The YAML configuration file serves as the central configuration for DeployEx, controlling both installation and runtime behavior. DeployEx fetches this configuration from the path specified in `DEPLOYEX_CONFIG_YAML_PATH`.

## Installation

DeployEx can be installed directly on **Ubuntu 24.04/Debian** servers using the [deployex script](/devops/installer/deployex.sh) included in the release package. This script supports multiple operations using the same YAML configuration file:

```bash
Usage:
  ./deployex.sh --install [config_file] [--dist <base_url>]
  ./deployex.sh --update [config_file] [--dist <base_url>]
  ./deployex.sh --uninstall [config_file]
  ./deployex.sh --hot-upgrade <release_path> [config_file]
  ./deployex.sh --help
```

**Installation Commands:**
- `--install` - Initial DeployEx installation
- `--update` - Update existing DeployEx installation
- `--uninstall` - Remove DeployEx installation
- `--hot-upgrade` - Apply hot-upgrade to running DeployEx instance

For installation examples, see:
- [Calori Web Server - AWS Setup](https://github.com/thiagoesteves/calori/blob/main/devops/aws/terraform/modules/standard-account/cloud-config.tpl)
- [Calori Web Server - GCP Setup](https://github.com/thiagoesteves/calori/blob/main/devops/gcp/terraform/modules/standard-account/cloud-config.tpl)
- [Example YAML Configuration](/devops/installer/deployex-aws.yaml)

## Configuration Structure

```yaml
# ============================================================================
# DEPLOYEX CONFIGURATION
# ============================================================================

account_name: "prod"                                     # Cloud/Environment Account name
hostname: "deployex.myphoenixapp.com"                    # Deployex hostname
port: 5001                                               # Deployex port
scheme: "https"                                          # Public URL scheme: https (port 443) or http (port 80) (optional)
check_origin: ["//deployex.myphoenixapp.com"]           # Endpoint origin check: list of allowed origins, or false (optional)

# Release Distribution
release_adapter: "s3"                                    # Release adapter: s3, gcp-storage or local
release_bucket: "myphoenixapp-prod-distribution"         # Release distribution bucket name

# Secrets Management
secrets_adapter: "aws"                                   # Secrets adapter: aws, gcp, env, 1password-connect or 1password-cli
secrets_path: "deployex-myphoenixapp-prod-secrets"       # Secret path to retrieve from

# Cloud Provider Configuration
aws_region: "sa-east-1"                                  # AWS region (only for AWS)
google_credentials: "/home/ubuntu/gcp-config.json"       # Google credentials (only for GCP)

# System Configuration
version: "0.10.0"                                        # DeployEx version
otp_version: 28                                          # OTP version (must match monitored apps)
os_target: "ubuntu-24.04"                                # Target OS server. The installer picks the amd64 or arm64 build
enable_release_check: true                               # Hourly GitHub check for a newer DeployEx (optional, default: true)

# Path Configuration (optional with defaults)
otp_tls_certificates: "/usr/local/share/ca-certificates" # Path to TLS certificates
install_path: "/opt/deployex"                            # DeployEx installation path (default: /opt/deployex)
var_path: "/var/lib/deployex"                            # DeployEx managed data path (default: /var/lib/deployex)
log_path: "/var/log/deployex"                            # DeployEx logs path (default: /var/log/deployex)
monitored_app_log_path: "/var/log/monitored-apps"        # Monitored apps log path (default: /var/log/monitored-apps)

# Data Retention (optional with defaults)
metrics_retention_time_ms: 3600000                       # Metrics retention: 1 hour (default: 3600000)
logs_retention_time_ms: 3600000                          # Logs retention: 1 hour (default: 3600000)
releases_retention: 2                                    # Releases kept per app after a hot upgrade (default: 2, minimum: 2)

# ============================================================================
# EXTERNAL NOTIFICATIONS (optional)
# ============================================================================

notifications:
  # Webhook adapter — subscribe to every event using "all"
  - adapter: "webhook"                                   # Adapter: webhook, slack or pagerduty
    url: "https://example.com/hooks/deployex"            # HTTP POST destination
    enabled: true
    events:
      - "all"                                            # Expands to all supported events automatically

  # Webhook adapter — or list individual events
  - adapter: "webhook"
    url: "https://example.com/hooks/deployex-critical"
    enabled: true
    events:                                              # One or more of the supported events
      - "crash_restart"                                  # Monitored app crashed and was restarted
      - "deployment_started"                             # New deployment was initiated
      - "deployment_complete"                            # Deployment finished (success or failure)
      - "application_ready"                              # App reported itself running, whatever put it there
      - "deployment_shutdown"                            # App was force-terminated (will restart)
      - "watchdog_threshold_exceeded"                    # Resource reached the restart threshold, restarted or not
      - "watchdog_threshold_warning"                     # Resource crossed warning threshold (or normalized)
      - "certificate_renewed"                            # TLS certificate successfully renewed
      - "certificate_valid"                              # Periodic check found a still-valid certificate
      - "certificate_failed"                             # TLS certificate renewal failed
      - "config_changed"                                 # Upgradable config change detected in YAML
      - "config_change_applied"                          # Pending config changes successfully applied
      - "pre_command_failed"                             # A pre-command failed. Retries report each command once
      - "version_ghosted"                                # A version was ghosted, this host does not deploy it again
      - "deployment_rollback"                            # An instance starts to go back from a version ghosted here

  # Slack Incoming Webhook adapter
  - adapter: "slack"
    url: "https://hooks.slack.com/services/T.../B.../..." # Slack Incoming Webhook URL
    enabled: true
    events:
      - "crash_restart"
      - "deployment_complete"
      - "watchdog_threshold_exceeded"
    options:
      username: "DeployEx"                               # Bot display name (default: DeployEx)
      icon_emoji: ":rocket:"                             # Bot icon emoji (default: :robot_face:)

  # PagerDuty Events API v2 adapter
  - adapter: "pagerduty"
    enabled: true                                        # url: omit to use the default PagerDuty endpoint
    events:
      - "crash_restart"
      - "deployment_shutdown"
      - "watchdog_threshold_exceeded"
      - "certificate_failed"
    options:
      routing_key: "abc123def456..."                     # PagerDuty integration key (required)

# ============================================================================
# AUTHENTICATION (optional)
# ============================================================================
# Optional single sign-on. When absent, only the built-in password login is
# available. When client_id, redirect_uri and DEPLOYEX_OAUTH_CLIENT_SECRET are
# all set, the login page shows a provider button. With only some of them set,
# DeployEx logs a warning at startup and keeps the button off. Access is
# deny-by-default: only allow-listed emails or domains may sign in. The GitHub
# account's primary email must be verified and allowed. The client_secret is a
# secret, so it is not set here. Provide it through the secrets adapter as
# DEPLOYEX_OAUTH_CLIENT_SECRET. The auth section can be changed at runtime, but
# the client secret is read only when DeployEx starts.
# A domain entry trusts every GitHub account that has ever verified an address
# at that domain, including people who have left. Prefer allowed_emails, and
# remove the entry to end a person's access.

auth:
  provider: "github"                                     # Provider: github
  client_id: "Ov23liExample"                             # GitHub OAuth App client id (not a GitHub App)
  redirect_uri: "https://deployex.example.com/auth/github/callback" # Required, the OAuth App callback, path /auth/github/callback
  allowed_emails:                                        # Exact emails allowed to sign in
    - "alice@example.com"
  allowed_domains:                                       # Whole domains allowed to sign in
    - "example.com"

# ============================================================================
# AGENT API (optional)
# ============================================================================
# A JSON API and an event stream on their own port, off by default.
# Each request needs a bearer token from DEPLOYEX_API_TOKENS, a secret that the
# secrets adapter provides. The section is read when DeployEx starts. See the
# Agent API guide.

agent_api:
  enabled: true                                          # Turn the listener on (optional, default: false)
  port: 5002                                             # Listen port (optional, default: 5002)
  # certfile: "/etc/deployex/api.crt"                    # Serve only HTTPS (optional, with keyfile, must exist at boot)
  # keyfile: "/etc/deployex/api.key"                     # Private key of the certificate (optional, with certfile)

# ============================================================================
# DEPLOYEX MONITORING (optional)
# ============================================================================

monitoring:
  # Supported types are memory, atom, process and port, any other type is rejected. A type that
  # is not listed here is not monitored at all, while a listed type without thresholds falls
  # back to the defaults below
  # Host memory. Exceeding the restart threshold restarts the monitored application
  # consuming the most memory, not DeployEx
  - type: "memory"
    enable_restart: true           # Restart app if memory exceeds restart threshold (default: true)
    warning_threshold_percent: 75  # Issue warning at this memory usage (default: 75)
    restart_threshold_percent: 90  # Restart app at this memory usage (default: 90)
  # DeployEx own Beam VM limits. Exceeding the restart threshold terminates DeployEx
  # itself, which systemd then restarts, so enable_restart is opt-in
  - type: "atom"
    enable_restart: false          # Terminate DeployEx if the atom table exceeds the restart threshold (default: true)
    warning_threshold_percent: 75  # Issue warning at this atom table usage (default: 75)
    restart_threshold_percent: 90  # Terminate DeployEx at this atom table usage (default: 90)
  - type: "process"
    enable_restart: false          # Terminate DeployEx if the process count exceeds the restart threshold (default: true)
    warning_threshold_percent: 75  # Issue warning at this process count usage (default: 75)
    restart_threshold_percent: 90  # Terminate DeployEx at this process count usage (default: 90)
  - type: "port"
    enable_restart: false          # Terminate DeployEx if the port count exceeds the restart threshold (default: true)
    warning_threshold_percent: 75  # Issue warning at this port count usage (default: 75)
    restart_threshold_percent: 90  # Terminate DeployEx at this port count usage (default: 90)

# ============================================================================
# MONITORED APPLICATIONS
# ============================================================================

applications:
  # --------------------------------------------------------------------------
  # Application: myphoenixapp
  # --------------------------------------------------------------------------
  - name: "myphoenixapp"               # App name (Elixir app name format)
    language: "elixir"                 # App language: elixir, erlang or gleam (default: elixir)
    replicas: 2                        # Number of replicas (default: 3)
    
    # Deployment Configuration (optional with defaults)
    deploy_rollback_timeout_ms: 600000 # Max deployment time before rollback, and max time for hot upgrade pre-commands to start and to run (default: 600000)
    deploy_schedule_interval_ms: 5000  # Check for new deployments interval (default: 5000)

    # Readiness Configuration (optional with defaults)
    readiness:
      type: "otp"                      # timeout, otp or http (default: otp)
      min_ready_ms: 30000              # Min time the application stays up before it counts as ready (default: 30000)
      # scheme: "https"                # http only, optional (default: http)
      # port_key: "PORT"               # http only, required, must be a key in replica_ports
      # path: "/ready"                 # http only, required, must start with /
    
    # Port Configuration (optional)
    replica_ports:                     # Each replica gets: base + replica_index
      - key: PORT
        base: 4000                     # First replica: 4000, second: 4001, etc.
    
    # Environment Variables (optional). Each value reaches the monitored app as written,
    # spaces and shell characters included, with no shell expansion.
    env:
      - key: MYPHOENIXAPP_PHX_HOST
        value: "myphoenixapp.com"
      - key: MYPHOENIXAPP_PHX_SERVER
        value: true
      - key: MYPHOENIXAPP_CLOUD_ENVIRONMENT
        value: "prod"
      - key: MYPHOENIXAPP_OTP_TLS_CERT_PATH
        value: "/usr/local/share/ca-certificates"
      - key: MYPHOENIXAPP_SECRETS_ADAPTER
        value: "aws"
      - key: MYPHOENIXAPP_SECRETS_PATH
        value: "myphoenixapp-prod-secrets"
      - key: AWS_REGION
        value: "sa-east-1"

    # Secrets (optional). The fields of a 1Password item, passed to the monitored app as
    # environment variables every time it starts. See "Secrets from 1Password"
    secrets:
      adapter: "1password-connect"     # 1password-connect or 1password-cli
      path: "vaults/production/items/myphoenixapp"
    
    # Application-Level Monitoring (optional with defaults)
    # Supported types are atom, process and port, any other type is rejected
    monitoring:
      - type: "atom"                   # Monitor atom table usage
        enable_restart: true           # Restart if exceeded (default: true)
        warning_threshold_percent: 75  # Warning threshold (default: 75)
        restart_threshold_percent: 90  # Restart threshold (default: 90)
      - type: "process"                # Monitor process count
        enable_restart: true
        warning_threshold_percent: 75
        restart_threshold_percent: 90
      - type: "port"                   # Monitor port usage
        enable_restart: true
        warning_threshold_percent: 75
        restart_threshold_percent: 90

    # Application-Level Certificates configuration
    certificates: 
      - type: "domains"
        domains: ["*.calori.com.br" , "*.hub.calori.com.br" ] # Domains included in the certificate
        certificate_check_interval_ms: 86400000               # Periodic renewal check interval
        dns_propagation_timeout_ms: 120000                    # DNS propagation configuration  
        dns_check_interval_ms: 5000
        renew_before_days: 30                                 # Renew certificate before expiration
        dns_provider: "cloudflare"                            # DNS provider (Supports route53 or cloudflare)
        dns_options: 
          ttl: 10 
          zone: "Z0123456789ABCDEFG"
          api_token: "ABC123GHB"                              # For cloudflare only
        acme_provider: "lets_encrypt"                         # ACME provider (Supports lets_encrypt)
        acme_options: 
          contact_email: "myapp@mydomain.com" 
          url: "https://acme-v02.api.letsencrypt.org/directory" 
          key_size: 2048
          propagation_timeout_ms: 120000
          check_interval_ms: 2000
        importer: "route53"                                   # Certificate deployment/import (Supports route53)
        importer_options: 
          certificate_arn: "arn:aws:acm:us-east-1:123456789012:certificate/xxxxxxxx"
        storage_options:                                      # Optional, write the certificate to disk on renewal
          certificate_path: "/etc/ssl/myapp/host.pem"
          private_key_path: "/etc/ssl/myapp/host-key.pem"

  # --------------------------------------------------------------------------
  # Application: myapp
  # --------------------------------------------------------------------------
  - name: "myapp"
    language: "elixir"
    replicas: 2
    
    replica_ports:
      - key: PORT
        base: 4040
    
    env:
      - key: MYAPP_PHX_HOST
        value: "myapp.com"
      - key: MYAPP_PHX_SERVER
        value: true
      - key: MYAPP_CLOUD_ENVIRONMENT
        value: "prod"
      - key: MYAPP_OTP_TLS_CERT_PATH
        value: "/usr/local/share/ca-certificates"
      - key: MYAPP_SECRETS_ADAPTER
        value: "aws"
      - key: MYAPP_SECRETS_PATH
        value: "myapp-prod-secrets"
      - key: AWS_REGION
        value: "sa-east-1"
```

## Secrets from 1Password

DeployEx can read secrets from 1Password in two places:

- **Its own secrets**, with `secrets_adapter` and `secrets_path` at the top of the file, like the `aws`, `gcp` and `env` adapters.
- **The secrets of a monitored application**, with the `secrets` section of the application. DeployEx reads them every time it starts the application and passes them to it as environment variables. This is what the 1Password Kubernetes operator does with a Secret and `envFrom`.

Both take the same two values. The adapter says how 1Password is reached, the path says which item holds the secrets:

```yaml
secrets_adapter: "1password-connect"
secrets_path: "vaults/production/items/deployex"

applications:
  - name: "myphoenixapp"
    secrets:
      adapter: "1password-connect"
      path: "vaults/production/items/myphoenixapp"
```

### The item

The path is `vaults/<vault>/items/<item>`, the format of the operator's `item-path` annotation.
Each part is a name or an ID, and a name cannot contain a `/`.
When several vaults or items share a name the oldest one is used, as the operator does.

Each field of the item is one secret: the label of the field is its name and the value of the field is its value.
For DeployEx's own secrets the labels are the names in the README, such as `DEPLOYEX_SECRET_KEY_BASE`.
For an application they are the names of the environment variables it reads, such as `DATABASE_URL`.

- A field without a value is left out, and when two fields have the same label the later one wins. The operator does the same.
- The notes of the item, its URLs and its file attachments are not read. The operator does read them.
- A field of an application is left out when its label is not a valid environment variable name, or starts with `RELEASE_` or `DEPLOYEX_`, which DeployEx removes from the environment of every application it starts. The labels left out are logged, values never are.

### Reaching 1Password

| Adapter | How | Needs |
|---|---|---|
| `1password-connect` | The REST API of a [1Password Connect server](https://developer.1password.com/docs/connect/) | `OP_CONNECT_HOST` (for example `http://connect.internal:8080`) and `OP_CONNECT_TOKEN` |
| `1password-cli` | The `op` command line tool, version 2.30 or later, in the `PATH` of DeployEx | `OP_SERVICE_ACCOUNT_TOKEN`, a [service account](https://developer.1password.com/docs/service-accounts/) token. `op` uses a Connect server instead when `OP_CONNECT_HOST` and `OP_CONNECT_TOKEN` are set |

These are the variable names the 1Password tools use, and they are read from the environment of DeployEx.
They cannot come from the secrets adapter, which is what they give access to.
On a host installed with `deployex.sh`, give them to the service with a systemd drop-in that points to a file only root can read:

```bash
sudo install -d -m 0700 /etc/systemd/system/deployex.service.d
sudo install -m 0600 /dev/null /etc/systemd/system/deployex.service.d/onepassword.env
sudoedit /etc/systemd/system/deployex.service.d/onepassword.env
# OP_CONNECT_HOST=http://connect.internal:8080
# OP_CONNECT_TOKEN=...
printf '[Service]\nEnvironmentFile=/etc/systemd/system/deployex.service.d/onepassword.env\n' |
  sudo tee /etc/systemd/system/deployex.service.d/onepassword.conf
sudo systemctl daemon-reload
sudo systemctl restart deployex.service
```

- **Use `EnvironmentFile=`, not `Environment=`.** systemd shows the `Environment=` lines of a unit to every user of the host, with `systemctl show`, whatever the mode of the file they are written in. Of an `EnvironmentFile=` it shows only the path.
- **`deployex.sh --install` and `--update` keep the drop-in**, they only rewrite the unit file. `--uninstall` removes the whole `deployex.service.d` directory, the credentials with it.
- **`deployex.sh` warns when they are missing.** On `--install` and `--update`, when the YAML uses a 1Password adapter and the service is not given the variables that adapter needs, or `op` is not installed for `1password-cli`, it prints a warning before it starts the service. It reads the names of the variables, never their values.

A monitored application starts as a child of DeployEx, so DeployEx removes these three variables from the environment of every application it starts.
An application that needs 1Password credentials of its own gets them as fields of its item.

### What to expect for an application

- **The secrets are read at every start**: a full deployment, a restart from the dashboard and a restart after a crash. A value changed in 1Password reaches the application at its next start.
- **A hot upgrade reads them again.** The application keeps its OS process, so DeployEx puts the secrets in the environment of the running node before it resolves the configuration of the new version: a changed value and a new secret are set, and a secret that left the item is removed. What the new `runtime.exs` reads is then what the item holds now.
- **A hot upgrade changes the configuration, not what already used it.** The application gets the keys that changed in `config_change/3`. A value read on each use is the new one from then on. A value a process took when it started, such as the password of a database pool, stays until that process restarts, which the application does from `config_change/3` or a restart from the dashboard does.
- **A hot upgrade goes on when the secrets cannot be refreshed.** The node keeps the secrets it has and DeployEx logs a warning. A release that needs a secret the node does not have then fails to resolve its configuration and is not installed.
- **An application is not started without its secrets.** When the item cannot be read at the first start of an instance, DeployEx logs why and tries again, as it does for a failing pre-command.
- **A restart does not depend on 1Password being reachable.** When the item cannot be read at a later start, the instance starts with the secrets of its previous start and DeployEx logs a warning. They are kept in memory, and not across a restart of DeployEx.
- **The pre-commands get the same secrets**, so a migration can reach the database.
- **The values are not written anywhere.** They are passed in the environment of the process, not on its command line, and they are not in the logs, the dashboard or the Agent API. The dashboard shows only the adapter and the path.

### An application that reads its own secrets

The `secrets` section is not the only way for an application to get fresh secrets on a hot upgrade.
An application whose release has a [Config Provider](https://hexdocs.pm/elixir/Config.Provider.html) that reads its secrets itself, from 1Password, AWS or anywhere else, needs nothing from DeployEx for it:

```elixir
releases: [
  myphoenixapp: [
    config_providers: [{Myphoenixapp.SecretsProvider, "myphoenixapp-prod-secrets"}]
  ]
]
```

DeployEx runs the Config Providers of the application again on every hot upgrade, on the running node, and applies what they return, see [What happens to configuration during a hot-upgrade](/guides/docs/hot-upgrades/README.md#what-happens-to-configuration-during-a-hot-upgrade).
A provider that reads the secret store returns what it holds at that moment, and the application gets the keys that changed in `config_change/3`.

How the two compare:

| | `secrets` section | Config Provider of the application |
|---|---|---|
| Who reads the secret store | DeployEx | The application, with its own credentials |
| Where the values end up | The environment of the OS process, then the configuration through `runtime.exs` | The configuration of the application, never its environment |
| On a start | Read by DeployEx before the application starts. A restart falls back to the secrets of the previous start | Read by the application while it boots. A store that cannot be reached stops the boot |
| On a hot upgrade | Read again and set on the running node | Read again by the provider |
| When the store cannot be reached on a hot upgrade | The upgrade goes on with the secrets the node has | The provider fails, and the release is not installed |

Three things to know about a provider on a hot upgrade:

 * It runs on the node as it is, in the version that is being replaced. A fix to the provider itself only takes effect after a full deployment.
 * It runs in a system that is already started. A provider that starts a process under a fixed name, such as an HTTP client pool, has to tolerate that process already being there.
 * It changes the configuration, not what already used it, as with the `secrets` section.

Both can be used by the same application: the provider runs after the environment is set, so it can read from it.

## Running behind a TLS-terminating proxy

DeployEx can run behind anything that terminates TLS and forwards plain HTTP to the box: an
AWS ALB with ACM, a CDN edge, or nginx on the same host. `port` is where DeployEx listens. Two
optional endpoint keys describe the public address:

- `scheme` sets the public URL scheme and port: `"https"` gives port 443 and `"http"` gives
  port 80. Without it, a release keeps its built-in public URL, `https` on port 443.
- `check_origin` sets the origin check for LiveView sockets. The default already works behind
  a proxy, because it compares only the origin host with `hostname`. Give a list of allowed
  origins when the dashboard is also reached by another host name. Each entry needs a host that
  `URI.parse/1` can read, so write `"//host"` or `"https://host"`, not a bare `"host"`. Set
  `false` only as a last resort, because it turns off the check.

DeployEx loads both keys at boot and stops with an error if a value is not supported.

```yaml
hostname: "deployex.myphoenixapp.com"
port: 5001            # what DeployEx listens on behind the proxy
scheme: "https"       # what the public request arrives as
check_origin: ["//deployex.myphoenixapp.com", "//deployex-alb.example.com"]
```

DeployEx does not trust `X-Forwarded-*` headers, so `conn.scheme`, host, and port show the
request from the proxy.

## Runtime Configuration Upgrades

DeployEx supports **runtime configuration upgrades** for certain settings, enabling dynamic updates without service interruption. Changes are automatically detected, validated, and presented in the UI for approval.

### Upgradable Configuration Fields

These fields can be modified and applied at runtime without restarting DeployEx:

#### DeployEx Level (Runtime Upgradable)
- `logs_retention_time_ms` - Log data retention period
- `metrics_retention_time_ms` - Metrics data retention period
- `releases_retention` - Releases kept per app after a hot upgrade (minimum 2)
- `monitoring` - DeployEx monitoring settings (host memory, atom, process, port thresholds)
- `notifications` - External notification channels (workers are stopped and restarted on apply)
- `auth` - Single sign-on settings: enable or disable it, change the provider settings, or add and remove allowed emails and domains (see below)

#### Authentication

Adding the `auth` section enables single sign-on, and removing it disables it, without a restart.
Allowed emails and domains can be added or removed the same way.
After the change is applied, every request checks the session against the new settings.
Open pages of a user who is no longer allowed, or of any SSO user when SSO is disabled, are redirected to the login page.
Password logins are not affected.

The `DEPLOYEX_OAUTH_CLIENT_SECRET` secret is read only when DeployEx starts.
To enable single sign-on without a restart, provide the secret before DeployEx starts, even if the `auth` section is added later.
If the secret is missing when the `auth` section is applied, DeployEx logs a warning and the sign-in button stays hidden.

#### Application Level (Runtime Upgradable)
- `monitoring` - Application monitoring settings (atom, process, port thresholds)
- `certificates` - Application certificate settings (acme, dns provider, importer)
- `language` - Application language (Elixir, Erlang, Gleam)
- `replicas` - Number of application instances
- `deploy_rollback_timeout_ms` - Deployment rollback timeout. A hot upgrade also gives its pre-commands this long to start, and this long to run once they start
- `deploy_schedule_interval_ms` - Deployment check interval
- `replica_ports` - Port configuration for replicas
- `env` - Environment variables
- `readiness` - When a started application counts as ready, which is when the previous version stops. Applied on the next deployment. See [Application Readiness](#application-readiness)
- `secrets` - Where the application's secrets are read from. Applied on the next deployment, an instance that already runs keeps the secrets it was started with. See [Secrets from 1Password](#secrets-from-1password)

#### Application Readiness

The rollback window closes and the previous version stops when the new instance counts as ready.
`deploy_rollback_timeout_ms` is the deadline: a version that does not get ready in time is ghosted and the previous version keeps running.

- `timeout` - The OS process stays up for `min_ready_ms`. This does not check the application, so one that stays up but never serves still replaces the previous version.
- `otp` (default) - The OS process stays up for `min_ready_ms`, and the node reports over OTP distribution that its boot script finished. This requires no change to the application, but it does not check that the application is serving requests or can reach its dependencies. A Gleam application boots from `-eval`, after the boot script, so for Gleam this only checks that the node is up and answering, not that `main` finished its own setup.
- `http` - The OS process stays up for `min_ready_ms`, and DeployEx requests `<scheme>://127.0.0.1:<port><path>` on the instance and expects a 2xx response. `port` comes from `replica_ports`, selected by `port_key`, which is validated to be one of its keys when the YAML loads. `path` must start with `/` and is also validated at load. With `scheme: "https"` the probe does not verify the certificate, because it connects by IP address and the certificate is issued for the application's domain. Redirects are not followed and count as a failure, so an application that redirects HTTP to HTTPS must use `https` or exclude the probe path from the redirect. The endpoint should check that the application can serve requests, including reachability of dependencies such as a database or cache.

#### Application Certificates

DeployEx supports automatic TLS certificate provisioning, renewal, and deployment using ACME providers such as Let's Encrypt. Certificates are configured per application through the certificates field. This allows applications to manage HTTPS certificates without requiring external automation.

#### Writing the certificate to disk

`importer` hands the certificate to a cloud service, which covers a load balancer terminating TLS but not a process that has to read the certificate from the filesystem. `storage_options` covers that case: give it the paths and DeployEx writes them every time the certificate is renewed.

```yaml
storage_options:
  certificate_path: "/etc/ssl/myapp/host.pem"
  private_key_path: "/etc/ssl/myapp/host-key.pem"
```

Both keys are optional and independent: give one and only that file is written. Writing only the certificate is the useful case, for something that needs to present the chain without holding the key. Omitting both, or omitting `storage_options` entirely, disables the export.

The certificate is written as a full chain, leaf first followed by the intermediates, with mode `0644`. The private key is written with mode `0600`.

> [!IMPORTANT]
> DeployEx runs as the unprivileged `deployex` user, so the destination directory has to be writable by it. Paths such as `/etc/ssl` are root owned and will fail with `:eacces` until permission is granted:
> ```bash
> install -d -o deployex -g deployex -m 0750 /etc/ssl/myapp
> ```
> A failure to write is logged but does **not** fail the renewal. The certificate has already been issued and imported at that point, and failing would make the manager retry and reissue against the Let's Encrypt weekly limit.

The same export is available on demand, which is useful for placing an already issued certificate without waiting for a renewal:

```elixir
Foundation.Certificate.export_to_files("myapp", "/etc/ssl/myapp/host.pem", "/etc/ssl/myapp/host-key.pem")
```

### Non-Upgradable Configuration Fields

These fields require a **full DeployEx restart**:

#### Core System Configuration
- `account_name` - Cloud/Environment identifier
- `hostname` - DeployEx hostname
- `port` - DeployEx port

#### Infrastructure Configuration
- `release_adapter` - Release distribution adapter
- `release_bucket` - Release bucket name
- `secrets_adapter` - Secrets provider
- `secrets_path` - Secrets path
- `aws_region` - AWS region
- `google_credentials` - GCP credentials path
- `agent_api` - Agent API listener, port and TLS files

#### System Requirements
- `version` - DeployEx version
- `otp_version` - OTP version
- `otp_tls_certificates` - TLS certificate path
- `os_target` - Target operating system
- `enable_release_check` - GitHub check for a newer DeployEx release

#### Installation Paths
- `install_path` - DeployEx installation directory
- `var_path` - Managed data directory
- `log_path` - DeployEx logs directory
- `monitored_app_log_path` - Monitored apps logs directory

### How Runtime Upgrades Work

1. **Automatic Detection** - DeployEx periodically checks the YAML file for changes using checksum comparison
2. **Validation** - Changes are validated to ensure only upgradable fields are modified
3. **UI Approval** - Detected changes appear in the UI for review and approval
4. **Application** - Approved changes are applied based on their upgrade type

### Runtime Upgrade Types

Each configuration change is classified by its application method:

| Type | Description | Service Impact |
|------|-------------|----------------|
| **immediate** | Applied instantly | No interruption |
| **next_deploy** | Applied during next deployment | Minimal interruption |
| **full_deploy** | Requires full redeployment | Service interruption |

> **Note:** When `full_deploy` changes are combined with other types, they are applied last after all other changes.

### Configuration Upgrade Examples

#### Example 1: Adjusting Monitoring Thresholds (Immediate)

```yaml
# Original configuration
monitoring:
  - type: "memory"
    enable_restart: true
    warning_threshold_percent: 75
    restart_threshold_percent: 90

# Updated configuration - applied immediately at runtime
monitoring:
  - type: "memory"
    enable_restart: true
    warning_threshold_percent: 80  # ✓ Increased threshold
    restart_threshold_percent: 95  # ✓ Increased threshold
```

#### Example 2: Scaling Application Replicas (Next Deploy)

```yaml
applications:
  - name: "myphoenixapp"
    language: "elixir"
    replicas: 3  # Changed from 2 to 3
    # Applied during next deployment cycle
```

#### Example 3: Updating Retention Policies (Immediate)

```yaml
# Original
metrics_retention_time_ms: 3600000  # 1 hour
logs_retention_time_ms: 3600000     # 1 hour

# Updated - applied immediately at runtime
metrics_retention_time_ms: 7200000  # ✓ 2 hours
logs_retention_time_ms: 10800000    # ✓ 3 hours
```

#### Example 4: Granting Access to a New User (Immediate)

```yaml
auth:
  provider: "github"
  client_id: "Ov23liExample"
  redirect_uri: "https://deployex.example.com/auth/github/callback"
  allowed_emails:
    - "alice@example.com"
    - "bob@example.com"   # ✓ Can sign in once the change is applied
```

#### Example 5: Mixed Changes (Various Types)

```yaml
# Immediate changes
logs_retention_time_ms: 7200000

# Next deploy changes
applications:
  - name: "myphoenixapp"
    replicas: 3
    env:
      - key: NEW_FEATURE_FLAG
        value: true

# Full deploy required
port: 5003  # Changing DeployEx port requires restart
```