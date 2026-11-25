## Running DeployEx in a container

DeployEx is made for a host it shares with the applications it runs. This guide puts both in one container, so that a team that deploys with containers can try hot upgrades without changing how it deploys: the container is still what the platform schedules, restarts and replaces, and DeployEx changes the code of the application inside it.

It is a trial setup, with one container of DeployEx and one of nginx that share a network, the way two containers of a Kubernetes pod do. It runs with Docker alone, and as one pod on a local Kubernetes cluster, which is the last section. What it was run with, what was seen and what is still open are in each.

### How it is put together

```
                     the "pod": one network
      ┌──────────────────────────────────────────────────┐
 8080 │  nginx ──► 127.0.0.1:4000 or :4001                │
 ────►│                 ▲                                │
      │  DeployEx ──────┘ starts the application, and    │
 5001 │     ▲             upgrades it in place           │
 ────►│     │                                            │
      └─────┼────────────────────────────────────────────┘
            │
        ./bucket   the releases and current.json
```

 * **The image has DeployEx and no application.** The application comes from the bucket: a full deployment when the container starts, hot upgrades after that. A container that is replaced comes back on the version `current.json` points at.
 * **nginx gives the application one port.** DeployEx runs an instance on its base port plus 0 to `replicas`, and a full deployment starts the new instance on a free one before it stops the previous. One replica with a base of 4000 is on 4000 or 4001, and `nginx.conf` lists both: a request to a port where nothing listens is refused and sent to the other.
 * **The files are in [`devops/docker`](https://github.com/deployex/deployex/tree/main/devops/docker)**: the `Dockerfile` of DeployEx, `compose.yaml`, `deployex.yaml`, `nginx.conf`, and `publish-app.sh` with the `Dockerfile.app-builder` it uses.

### 1. Start DeployEx and nginx

From the root of this repository:

```bash
make docker-up
```

The first build compiles DeployEx from the source, which takes a few minutes. The dashboard is then at [http://localhost:5001](http://localhost:5001), user `admin` and password `deployex`. It has no application yet, the bucket is empty.

### 2. Publish an application

The application needs what any application managed by DeployEx needs, see [Elixir Application - No Ecto](../local-elixir/README.md): a release with [Jellyfish](https://github.com/deployex/jellyfish) as one of its steps, and the TLS distribution turned on when `/tmp/inet_tls.conf` exists. The sample application has both:

```bash
git clone https://github.com/thiagoesteves/myphoenixapp ../myphoenixapp
make docker-app
```

It publishes the version in the `mix.exs` of the application. `APP_DIR`, `APP_NAME` and `VERSION` name another one: `make docker-app APP_DIR=../myapp APP_NAME=myapp`. The script behind it, `devops/docker/publish-app.sh`, builds the release in a container, for the OS and the OTP of the DeployEx image, copies the tarball to `devops/docker/bucket` and writes `current.json`. DeployEx sees it within a few seconds and deploys it:

```bash
make docker-logs
# Update is needed at sname:  from: <no current set> to: 0.5.1
# Full deploy instance: 1 sname: myphoenixapp-xi0vd1
# Application sname: myphoenixapp-xi0vd1 is running
```

The application answers through nginx at [http://localhost:8080](http://localhost:8080).

### 3. Hot upgrade it

Change the application, set the next version in its `mix.exs`, and publish it:

```bash
make docker-app
```

The build directory is kept in a volume, so this build finds 0.5.1 and Jellyfish writes the appups:

```bash
# Update is needed at sname: myphoenixapp-xi0vd1 from: 0.5.1 to: 0.5.2
# HOT UPGRADE version DETECTED - [%Deployer.HotUpgrade.Jellyfish{name: "myphoenixapp", ...}]
# Release upgrade executed with success at node: myphoenixapp-xi0vd1@... from: 0.5.1 to: 0.5.2
```

The instance and its OS process are the same as before. A release with no appups, the first one built in a clean directory for instance, is a full deployment: a new instance on the other port, and the previous one stopped once the new one is running.

### The commands

| Command | What it does |
|---|---|
| `make docker-up` | Builds the image and starts DeployEx and nginx |
| `make docker-app` | Builds the application for the image and publishes it |
| `make docker-logs` | Follows the output of the DeployEx container |
| `make docker-down` | Stops and removes the containers |
| `make docker-clean` | Also removes the bucket and the build volumes of the application |
| `make k8s-up`, `k8s-logs`, `k8s-down` | The same as one pod on a local Kubernetes cluster, see [On Kubernetes](#on-kubernetes) |

### What was seen

With the sample application, on Docker 29 and an arm64 host, four requests a second through nginx:

| Step | Result |
|---|---|
| The container starts with 0.5.1 in the bucket | The application answered through nginx 12 seconds later |
| Hot upgrade, 0.5.1 to 0.5.2 | 345 requests, none failed. Same OS process before and after |
| Full deployment to 0.5.3 | 161 requests, none failed. The new instance on the other port, the previous one stopped 30 seconds later |
| The container removed and created again | Back on 0.5.3 in 12 seconds, read from the bucket |
| `docker compose stop` | Stopped in 11 seconds, exit code 0 |

### What to know before going further

 * **Both versions answer during a full deployment.** The new instance accepts connections a couple of seconds after it starts, and DeployEx waits for it to be ready, 30 seconds in the run above, before it stops the previous one. nginx sends requests to both meanwhile. Nothing failed, and a release that is bad would get half of the requests for that long. A proxy that checks a readiness path of the application before it sends traffic closes that window.
 * **The logs of the application are in the output of the container** because `deployex.yaml` sets `monitored_app_log_stdout: true`. An application writes to files under `/var/log/monitored-apps`, which DeployEx follows for its dashboard, and without that option `docker logs` and `kubectl logs` show DeployEx only. With it, each piece DeployEx reads is also written to its own output, unchanged, so the lines of an application that logs JSON stay JSON. The lines of DeployEx itself are in the same output, as text.
 * **The log files are rotated by logrotate**, which the image installs, with the rule the cloud guides put on a host: 20 MB a file, seven kept, `copytruncate` since the application keeps its file open. A container has no cron, so `entrypoint.sh` runs it every five minutes next to DeployEx, `LOGROTATE_INTERVAL_SECONDS` to change that.
 * **`SHELL` has to be set.** erlexec, which runs the applications, does not start without it, and a container sets none. The `Dockerfile` sets it.
 * **The certificates are made when the image is built.** They are for the TLS distribution between DeployEx and the applications, and are enough for a trial. Mount your own at `/certs` for anything else.
 * **The state is in the container.** `/var/lib/deployex` holds the releases that were installed, the history and the ghosted versions. It is gone with the container, which then starts from `current.json`. Mount a volume there to keep it.
 * **One memory limit covers both.** DeployEx and the application are in the same container, and a full deployment has two instances of the application for a while.
 * **The image is built from the source**, since it has to be the same OS and the same OTP as the release of the application, and a published DeployEx release is for one of each.

### On Kubernetes

The same two containers as one pod, on a local cluster made with [kind](https://kind.sigs.k8s.io). It needs `kind` and `kubectl` installed.

```bash
make k8s-up        # the cluster, the image, the ConfigMap, the Secret and the pod
make docker-app    # publishes to the same bucket, which the node mounts
make k8s-logs
make k8s-down
```

The dashboard is at [http://localhost:5011](http://localhost:5011) and the application at [http://localhost:8090](http://localhost:8090), through a NodePort Service. The cluster has a kubeconfig of its own, `devops/docker/kubernetes/kubeconfig`, so the contexts of your `kubectl` are not read or changed: `export KUBECONFIG=$PWD/devops/docker/kubernetes/kubeconfig` to look at it.

What is in [`devops/docker/kubernetes`](https://github.com/deployex/deployex/tree/main/devops/docker/kubernetes):

 * **One Deployment with one replica and the `Recreate` strategy**, so there are never two pods, each with its own DeployEx, on the same bucket.
 * **`deployex.yaml` and `nginx.conf` in a ConfigMap, the three secrets of DeployEx in a Secret.**
 * **The readiness probe is on nginx**, a request to the application through it: the pod is ready when the application answers, and not before one is published.
 * **A memory limit of 1.5 GB** on the DeployEx container, which covers DeployEx, the application and a second instance of it during a full deployment. DeployEx used 275 MB and the sample application 200 MB.
 * **The bucket is a directory of the node**, for the trial. On a real cluster it is `release_adapter: "s3"` or `"gcp-storage"`.

What was seen, with four requests a second through the Service:

| Step | Result |
|---|---|
| The pod starts with a version in the bucket | Ready, 2 of 2 containers, 16 seconds later |
| Hot upgrade | No request failed. The pod stayed ready and was not restarted |
| Full deployment | No request failed. The pod stayed ready and was not restarted |
| `kubectl logs` of the DeployEx container | Has the lines of the application |
| The pod deleted | Gone in 12 seconds, the new one ready 16 seconds after the delete. No answer for 15 seconds in between, there is one pod |

One thing only a cluster showed. The first pod was killed for its memory every time the application started, with the limit at 1.5 GB. A pod on containerd has a limit of open files of about a billion, where Docker gives a million, and the Erlang VM sizes its table of ports from that limit unless it is started with `+Q`. DeployEx is, the applications it starts usually are not, and their VM asked for gigabytes when it booted. `entrypoint.sh` now lowers the limit to 65536 before it starts DeployEx, which the applications inherit, `DEPLOYEX_MAX_OPEN_FILES` to change it.

The application can say it itself, which is the fix wherever it runs: `+Q 65536` in its `rel/vm.args.eex`, as in [Elixir Application - No Ecto](../local-elixir/README.md). With a limit of 1048576 open files the sample application reported a limit of 1048576 ports without it, and 65536 with it, once the pod had restarted: a hot upgrade does not apply a flag of the VM.

Still open, and what more than one pod will show: each pod has its own DeployEx and reads `current.json` by itself, so every pod acts on a new version within the same few seconds. Nothing orders them, the way the instances of one DeployEx are upgraded one after the other.
