# Running the harness from inside the cluster

The [Quick start](../README.md#quick-start) drives the harness from a
workstation. This is the same flow with the orchestrator moved into a pod on
the cluster under test.

## What this does and does not change

It changes nothing about the measurement. The README's
[Execution model](../README.md#execution-modelwhat-runs-where) already puts
every measured request inside the cluster: the load is a fortio Job hitting the
Gateway over service DNS, and the workstation only issues control calls. Moving
those control calls into a pod removes a failure mode — a laptop that sleeps, a
VPN that drops, an `oc exec` stream reset partway through a 45-minute matrix —
without touching what is on the measured path.

It does add one thing to account for: on a single-node cluster the runner pod
shares a node with the Gateway and the load generator. Its requests are
deliberately small (200m CPU) and it is idle while a run is in flight, but it
is one more tenant on the node, which is the confounder
[Confounders and risks](../README.md#confounders-and-risks) names first.

The guardrails in [CLAUDE.md](../CLAUDE.md) apply unchanged. In particular the
matrix is still one repeat per cell, so it is still indicative rather than
reportable until you run it three times.

## Pieces

| File | What it is |
|---|---|
| `docker/Dockerfile` | UBI9 + `oc`, `helm`, `python3` + PyYAML, `envsubst`, and the repo at `/opt/waf-perf-test` |
| `docker/runner.yaml` | Namespace, ServiceAccount, cluster-admin binding, results PVC, idle Deployment |
| `docker/build-and-deploy.sh` | Builds the image on the cluster and deploys the runner |
| `docker/run-in-cluster.sh` | Drives the quick start inside the pod |

The runner lives in its own namespace, `waf-perf-runner`, not in `waf-perf`:
`teardown.sh` deletes `waf-perf`, and a runner living there would delete
itself mid-flow.

`results/` is a PVC. A matrix is 45–55 minutes; losing it to a pod restart and
re-running silently is how a half-finished matrix ends up pooled with a
complete one in the same median.

## Build and deploy

```bash
docker/build-and-deploy.sh
```

Two builders, one Dockerfile, and the distinction matters:

- The **OpenShift binary BuildConfig** is what produces the deployed image. It
  builds on the cluster's own architecture and pushes straight into the
  internal registry, so there is no registry login, no TLS exception for a
  self-signed route, and no arch mismatch — the failure the operator chart's
  amd64-only image produces on arm64.
- A **local `docker build`** is a syntax and download check only. It is off by
  default (`LOCAL_BUILD=true` turns it on) because the image it produces cannot
  reach the cluster without making the Docker daemon trust the registry route.

## Drive the quick start

```bash
docker/run-in-cluster.sh check      # prereqs/check.sh
docker/run-in-cluster.sh prereqs    # prereqs/install-all.sh — a cluster change
docker/run-in-cluster.sh setup      # setup.sh
docker/run-in-cluster.sh matrix     # run-comprehensive-tests.sh, detached
docker/run-in-cluster.sh logs       # follow the detached run
docker/run-in-cluster.sh status     # is anything in flight?
docker/run-in-cluster.sh fetch ./results   # copy results out
docker/run-in-cluster.sh shell      # interactive
```

`prereqs` is still a cluster change and still belongs before the session you
intend to report, never between a baseline and a WAF-on run — installing or
upgrading Istio restarts the gateway proxy.

`matrix` and `suite` detach. `oc exec` holds one streaming connection for the
whole command, which is the same failure the harness already designs around by
running the measured load as a Job rather than an exec
([Why a Job](../README.md#why-a-job-and-why-outside-the-mesh)). Detached, a
dropped connection costs you the log tail rather than the run. `logs` reattaches.

Only one detached run at a time: two concurrent matrices on one cluster
interleave their load and both numbers are wrong while still looking plausible.

## Credentials

None are baked into the image. The pod authenticates with its ServiceAccount
token, which `oc` picks up on its own when `KUBECONFIG` is unset. Nothing in the
image or the manifests references a kubeconfig.

The ServiceAccount is bound to `cluster-admin`. `install-all.sh` installs CRDs,
a GatewayClass, a Helm release with its own ClusterRole, and then corrects that
ClusterRole from the operator bundle's CSV; enumerating that set would be a
second copy of the installer's RBAC, drifting against it.

## Recording the stack

The report renders "not recorded" for anything the results cannot carry. Read
the versions back and pass them in:

```bash
oc exec -n waf-perf-runner deploy/waf-perf-runner -- \
  env PLATFORM="OpenShift $(oc version -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["openshiftVersion"])')" \
      ISTIO_VERSION=... OPERATOR_VERSION=... \
      python3 scripts/report.py
```

`install-operator.sh` prints the chart version, the image digest and the CRD
commit at the end of a prereqs run. Record all three — together they are what
the number describes.
