# DeployEx Helm chart

Runs [DeployEx](https://github.com/deployex/deployex) as a Kubernetes StatefulSet, one pod per fleet member, each pod a DeployEx container next to an HAProxy sidecar.

This replaces hand-written manifests as the Kubernetes install path.
The [Docker and Kubernetes guide](https://github.com/deployex/deployex/blob/main/guides/docs/docker/README.md)'s `kind` trial, with its own raw manifests, is still there as the minimal, zero-Helm walkthrough of the same mechanism - this chart is for actually running it.

## Why a StatefulSet, not a Deployment

Two things fall out of this almost for free, that a Deployment would need extra work for:

- **Stable per-pod identity.** A pod named `deployex-0` keeps that name across restarts, and Kubernetes gives it a DNS record through the headless Service this chart also creates (`serviceName`). `peers_dns_query` needs every pod to resolve every other pod's bare short name - "deployex-0", not its full address - which this chart gets through `dnsConfig.searches` on the pod spec, rather than the `DEPLOYEX_NODE_HOST`/long-node-name workaround a Deployment's pods need instead, since their names aren't stable to begin with. Verified against a real `kind` cluster: from inside `deployex-1`, `getent hosts deployex-0` resolves to that pod's real IP.
- **A PersistentVolumeClaim per pod.** `volumeClaimTemplates` gives each pod its own volume at `/var/lib/deployex`, surviving a pod restart - the release history and ghosted versions DeployEx keeps for itself, which a plain `emptyDir` or a Deployment's pods (no stable identity to tie a volume to) cannot do per pod.

## Prerequisites

- **Your own image.** There is no published DeployEx image. Build one with the Dockerfile at the root of this repository and push it where `image.repository`/`image.tag` can reach it.
- **Release storage.** `deployexConfig.release_adapter` + `release_bucket`, reachable from every pod - S3 or GCS in practice, for anything beyond a single replica. `local` only makes sense for `replicaCount: 1`, and needs its own volume mounted at the path `release_bucket` names, via `extraVolumes`/`extraVolumeMounts` - it is not what `persistence` is for.
- **A Secret with DeployEx's own values**: `DEPLOYEX_SECRET_KEY_BASE`, `DEPLOYEX_ERLANG_COOKIE`, `DEPLOYEX_ADMIN_HASHED_PASSWORD` at least. Either `secret.create: true` from the values below (a trial only - the values end up in this release's own stored data, readable with `helm get values`), or `secret.existingSecret`, a Secret you made yourself, with the External Secrets Operator, or any other way.
  Generate the password hash the same way every other guide does, from an `iex` session: `Bcrypt.hash_pwd_salt("my-pass")`.

## Quick start

```bash
helm install my-deployex . \
  --set image.repository=my-registry/deployex \
  --set image.tag=0.10.0 \
  --set deployexConfig.release_adapter=s3 \
  --set deployexConfig.release_bucket=myphoenixapp-prod-distribution \
  --set deployexConfig.aws_region=sa-east-1 \
  --set secret.create=true \
  --set secret.secretKeyBase=<from: mix phx.gen.secret> \
  --set secret.erlangCookie=<any secret string> \
  --set secret.adminHashedPassword=<from: Bcrypt.hash_pwd_salt("my-pass")>
```

```bash
kubectl port-forward svc/my-deployex-dashboard 5001:5001
open http://localhost:5001   # admin / my-pass
```

It has no application yet - publish one to the release storage above, the same way as [step 2 of the Docker guide](https://github.com/deployex/deployex/blob/main/guides/docs/docker/README.md#2-publish-an-application), and DeployEx picks it up within a few seconds.

## Applications and HAProxy

`deployexConfig.applications` is the `applications:` section of `deployex.yaml`, passed through almost verbatim - see the [YAML guide](https://github.com/deployex/deployex/blob/main/guides/docs/yaml/README.md) for every field it takes.

`haproxy.config` is **not** generated from that list: it is the literal `haproxy.cfg` HAProxy starts with, the same file as [`devops/docker/haproxy.cfg`](https://github.com/deployex/deployex/blob/main/devops/docker/haproxy.cfg).
The chart's default matches one application on `replica_ports` base `4000` with one replica.
Edit it yourself to match your own applications, their ports, and how many replicas each one runs - the same hand-written file the Docker guide already asks for, just as a chart value instead of a file on disk.

## Fleet: more than one replica

Set `replicaCount` above `1` and every pod finds the others through the headless Service, deploys one at a time, and shows the rest on the Fleet page - see ["More than one pod"](https://github.com/deployex/deployex/blob/main/guides/docs/docker/README.md#more-than-one-pod).

What was true of the hand-written manifest is still true here: **each pod has its own dashboard and its own state.**
A session opened against one pod's dashboard is not known to another, and the versions one pod ghosted are not known to the others either.
This chart does not change that - it is a DeployEx limitation, not a Kubernetes one.

## Upgrading DeployEx itself vs. upgrading an application

These are two unrelated things, easy to conflate:

- **Bumping `image.tag` and running `helm upgrade` upgrades DeployEx itself**, as an ordinary Kubernetes rolling update of the StatefulSet - the pod is replaced, the same as a new image for any other container. This has nothing to do with hot upgrades.
- **An application hot upgrade never touches the pod or the container.** DeployEx applies it in place, from release storage, while the container (and DeployEx's own process inside it) keeps running untouched. See [Hot-Upgrades](https://github.com/deployex/deployex/blob/main/guides/docs/hot-upgrades/README.md).

Changing `image.tag` is exclusively about DeployEx's own version.
It is never how an application gets deployed or upgraded.

## Secrets of an application

`secret.create`/`secret.existingSecret` above is only for **DeployEx's own** secrets (`secrets_adapter: env` in `deployexConfig`, the default).

For an application's own secrets (a database URL, for instance), set its `secrets` section to the [directory adapter](https://github.com/deployex/deployex/blob/main/guides/docs/yaml/README.md#secrets-from-a-directory), mount the Secret that holds them with `extraVolumes`/`extraVolumeMounts`, and point `path` at where you mounted it:

```yaml
deployexConfig:
  applications:
    - name: myphoenixapp
      secrets:
        adapter: directory
        path: /etc/deployex/secrets/myphoenixapp

extraVolumes:
  - name: myphoenixapp-secrets
    secret:
      secretName: myphoenixapp-prod-secrets
extraVolumeMounts:
  - name: myphoenixapp-secrets
    mountPath: /etc/deployex/secrets/myphoenixapp
    readOnly: true
```

A Secret kept in sync by the External Secrets Operator, or one the Vault Agent injector writes, mounts the same way - this chart only mounts a volume, it never calls Kubernetes, ESO, or Vault's own APIs.

## CI/CD

Turn on `deployexConfig.agent_api` (off by default) to drive DeployEx from a pipeline instead of the dashboard, and check a rollout with [`rollout-guard`](https://github.com/deployex/rollout-guard) rather than a hand-rolled script - see the [Agent API guide](https://github.com/deployex/deployex/blob/main/guides/docs/agent-api/README.md).

## Values

| Key | Default | Description |
|---|---|---|
| `replicaCount` | `1` | Number of DeployEx pods. |
| `image.repository` | `""` | Required. Your own image - there is no published one. |
| `image.tag` | `""` | Required. |
| `image.pullPolicy` | `IfNotPresent` | |
| `haproxy.image` | `haproxy:3.2-alpine` | |
| `haproxy.config` | one app, one replica | The literal `haproxy.cfg`, not generated from `deployexConfig.applications`. |
| `haproxy.resources` | `{}` | |
| `deployexConfig` | see `values.yaml` | The contents of `deployex.yaml`. `peers_dns_query` and `agent_api.port` are filled in by the chart when left unset. |
| `service.app.*` | `ClusterIP`, port `80` → `8080` | The application, through HAProxy. |
| `service.dashboard.*` | `ClusterIP`, port `5001` | `publishNotReadyAddresses: true` - it has to answer before an application is published. |
| `service.agentApi.*` | `ClusterIP`, port `5002` | Created only when `deployexConfig.agent_api.enabled` is true. |
| `persistence.enabled` | `true` | A PVC per pod at `/var/lib/deployex`, via `volumeClaimTemplates`. |
| `persistence.size` | `1Gi` | |
| `persistence.storageClassName` | `""` | Cluster default when empty. |
| `secret.create` | `false` | Trial only - see Prerequisites. |
| `secret.existingSecret` | `""` | A Secret you made yourself. |
| `resources` | `{}` | On the `deployex` container. Size for DeployEx plus the application plus a second instance of it during a full deployment - see the Docker guide's own numbers as a starting point. |
| `podSecurityContext.fsGroup`, `securityContext.runAsUser`/`runAsGroup` | `1001` | The uid/gid of the image's `deployex` user, checked against the built image, not assumed - confirm it still matches if you build from a different base image. |
| `extraVolumes`, `extraVolumeMounts` | `[]` | An application's secrets, your own TLS certificates, anything else that needs a volume. |
| `extraEnv` | `[]` | `DEPLOYEX_MAX_OPEN_FILES`, `LOGROTATE_INTERVAL_SECONDS`, or anything else. |

## Tested against

`helm lint` and `helm template` on every change, plus, by hand against a real `kind` cluster before this chart's first version: a 3-replica install resolving peers by short name over `dnsConfig.searches`, a PVC bound per pod and actually written to by DeployEx, and the real image (built from this repository's own Dockerfile) booting, reading its Secret and ConfigMap correctly, and answering on the dashboard Service.
No automated self-test against a live cluster yet - see [What this does not do (yet)](#what-this-does-not-do-yet).

## What this does not do (yet)

- **Generate `haproxy.cfg` from `deployexConfig.applications`.** It is a value you write, matching the Docker guide's own hand-written file - not a gap introduced by this chart, the file was never generated there either.
- **Shared Fleet state across pods.** Each pod's dashboard and ghosted versions are still its own; see "Fleet" above.
- **A CI self-test against a live cluster**, the way [`rollout-guard`](https://github.com/deployex/rollout-guard)'s `ci.yml` runs against a fixture on every push. This chart was validated by hand against a real `kind` cluster once, not on every change yet.
- **TLS for the Agent API or the dashboard.** Terminate it at an Ingress, a mesh, or your cloud's load balancer in front of the Services this chart creates.
- **An Ingress.** `service.app`/`service.dashboard`/`service.agentApi` are plain Services; put whatever Ingress controller or mesh you already run in front of them.
