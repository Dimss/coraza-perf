# Coraza WAF Performance Testing

Harness for measuring what the WAF actually costs: the `coraza-proxy-wasm`
module running **inside the Envoy proxy of a Gateway pod**, driven by fortio
**from inside the cluster**.

The headline number this harness produces is never an absolute latency. It is
the **delta against a WAF-off baseline captured in the same session** — see
[Methodology](#methodology).

---

## Table of contents

- [Quick start](#quick-start)
- [Architecture](#architecture)
- [The three axes](#the-three-axes)
- [Components under test](#components-under-test)
- [Running tests](#running-tests)
- [Methodology](#methodology)
- [Results and reporting](#results-and-reporting)
- [Metrics and observability](#metrics-and-observability)
- [KPIs and acceptance criteria](#kpis-and-acceptance-criteria)
- [Confounders and risks](#confounders-and-risks)
- [Configuration knobs](#configuration-knobs)
- [Customization](#customization)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [File structure](#file-structure)
- [References](#references)

---

## Quick start

### 1. Prepare the cluster

A measurement run assumes Istio, the Gateway API CRDs and the Coraza operator
are already on the cluster. `setup.sh` does not check, and a missing piece
shows up as a hang on the Gateway readiness wait rather than an error, so
check first:

```bash
scripts/prereqs/check.sh         # what is missing
scripts/prereqs/install-all.sh   # install it (one-time; safe to re-run)
```

Nothing to set first — the platform is detected, and each script takes the
route that platform expects. What that means per platform:
[Environment requirements](#environment-requirements); the manual equivalents:
[docs/prerequisites.md](docs/prerequisites.md).

One thing it does not take from the chart. The chart's ghcr.io release image is
`linux/amd64` only, so on arm64 (CRC on Apple Silicon) the operator cannot
start at all. `install-operator.sh` therefore resolves its own: the newest
multi-arch Konflux build matching the architecture of the cluster's nodes, and
the CRDs from that build's commit. No arguments, nothing to set.

The CRDs come along because they have to. An operator newer than the chart
writes status to subresources the chart's schema does not define; it installs
cleanly, reports Ready on nothing, and `waf.sh on` times out on the RuleSet
much later. `check.sh` catches it.

That Konflux registry is staging — commit-SHA tags, no `latest`, builds get
garbage-collected — so it is for getting a cluster working, not for a number
you report. `install-operator.sh` prints the chart version, the image digest
the node actually resolved, and the CRD commit; record all three. To run a
build of your own instead, set `CORAZA_IMAGE_REPO` with `CORAZA_CRD_DIR`:
[Image and CRDs](docs/prerequisites.md#image-and-crds).

Run this before the session you intend to report — never between a baseline
and a WAF-on run, since installing Istio restarts the gateway proxy.

### 2. Run the perf test

```bash
scripts/setup.sh              # namespace, backend, loadgen, Gateway, payloads

# canonical run: WAF-off baseline first, then one measured run per ruleset
LOAD_PROFILE=args-heavy scripts/suite.sh scenarios/fixed-500qps.env minimal medium crs
```

`suite.sh` is the entry point to use. It captures the WAF-off baseline in the
same session, waits out the settle window after each toggle, and discards a
warm-up before every measured run — the number is meaningless without those.

**Invoke it at least three times per data point.** No script loops, and one run
is noise; the report medians the repeats it finds. Change one axis per run
(load intensity, request shape, ruleset size) and pin the other two.

For a one-off run of a single cell instead:

```bash
LOAD_PROFILE=baseline-get scripts/run.sh scenarios/fixed-500qps.env waf-crs
```

Or sweep the whole 3×4 matrix — one repeat per cell, so indicative only:

```bash
./run-comprehensive-tests.sh
```

It takes roughly **45–55 minutes**: 12 runs × (10s warm-up + 120s measured +
25s settle + overhead), plus a 15s pause between profiles.

When you are done:

```bash
scripts/teardown.sh           # deletes the namespace; results/ is kept
```

### 3. Generate the HTML report

Reporting needs no cluster — it reads the JSON already in `results/`. PyYAML
(`pip install -r requirements.txt`) lets it count rules out of the ruleset
manifests; without it the counts fall back to known values and it says so.

`suite.sh` runs it at the end of each invocation. Regenerate by hand after the
repeats, so the medians cover all of them. With no arguments it rebuilds every
scenario it finds — one page per scenario, covering every load profile measured
under it:

```bash
python3 scripts/report.py
# >> wrote results/fixed-500qps-report.html
#    scenario 'fixed-500qps': 3 profile(s) x 4 ruleset(s), 12/12 cells, 12 runs
open results/fixed-500qps-report.html
```

`--scenario <name>` narrows it to one, and `--out <file>` overrides the
destination for that one scenario. Point `--results` at a single run directory
to report on that session alone — which is what `suite.sh` does for the report
it drops inside each one:

```bash
python3 scripts/report.py --results results/fixed-500qps-311026102345
```

Read p95 and p99, never the average, and read the WAF cost as the delta against
the `waf-off` column rather than the absolute figure.

The page can only state what the results carry. Set these to have it name the
cluster too, otherwise they render as "not recorded":

```bash
PLATFORM="OpenShift 4.22.18" ISTIO_VERSION="v1.27.5" OPERATOR_VERSION="v0.5.0" \
  python3 scripts/report.py
```

---

## Architecture

### Product: two planes

```
+----------------------------------+         +------------------------------------+
|         CONTROL PLANE            |         |          DATA PLANE                |
|  (Operator manager pod)          |         |  (Envoy + WASM in Gateway pods)    |
|                                  |         |                                    |
|  - RuleSource/RuleSet/Engine     |         |  - Intercepts every HTTP request   |
|    reconcilers                   |         |  - Runs Coraza WAF evaluation      |
|  - Compiles + validates SecLang  |         |  - Blocks / allows / detects       |
|  - RuleSetCache HTTP server      |<--poll--|  - Polls cache for rule updates    |
|    (:18080, in-memory, versioned)|--rules->|  - Emits coraza_waf_* metrics      |
|  - Applies WasmPlugin via SSA    |         |                                    |
|  Metrics: controller-runtime +   |         |  Metrics: coraza_waf_* on Envoy    |
|  coraza_* on :8443               |         |  stats port :15090                 |
+----------------------------------+         +------------------------------------+
```

The Coraza engine runs as a **WebAssembly module inside Envoy**. Every HTTP
request is evaluated inline by that filter, which makes it the most
performance-critical component in the system.

### Execution model — what runs where

The harness is **split**: orchestration is local, measurement is in-cluster.
Nothing of the harness itself is installed into the cluster — there is no test
controller, operator, or CI agent. The scripts are ordinary bash running on your
workstation, and every cluster interaction is a `kubectl`/`oc` call against the
API server, so a remote cluster works exactly like a local one.

| Runs on your workstation | Runs inside the cluster |
|---|---|
| `scripts/*.sh`, `run-comprehensive-tests.sh` — orchestration | `echo` backend Deployment — the target |
| `scripts/report.py` — reporting | `loadgen` Deployment (fortio server) — validity probes and the discarded warm-up, driven by `kubectl exec` |
| `results/` — all raw JSON, summaries, HTML | **one-off fortio Job per measured run** — the actual measurement |
| `curl` against a port-forwarded Prometheus (`collect.sh`) | Gateway pod (Envoy + `coraza-proxy-wasm`), operator pod, Prometheus |

**The measured traffic never leaves the cluster.** The Job hits the Gateway over
cluster-internal service DNS (`TARGET_URL`), so no part of the measured path
crosses your laptop's network. Your workstation only issues control calls and
collects results afterwards; its latency and link quality do not enter the
numbers.

Results come back out of the cluster with `kubectl logs job/<name>` once the Job
has finished — a single bounded fetch, not a live stream — and are parsed into
`results/` locally. `collect.sh` reaches Prometheus by `kubectl port-forward` to
`localhost` and queries it with `curl` from there.

### Test topology

```
  +-----------------------------------+
  |         your workstation          |
  |  scripts/*.sh   (orchestration)   |
  |  *.py           (reporting)       |
  |  results/       (raw JSON + HTML) |
  +-----------------+-----------------+
                    |
                    | kubectl / oc: apply CRs, wait, create Job,
                    | exec probes, read logs, port-forward Prometheus
                    v
  +-------------------------------------------------------------------+
  |                     Kubernetes cluster (SUT)                       |
  |                                                                    |
  |  +---------------+   +---------------+                             |
  |  | loadgen pod   |   | fortio Job    |   <- measured load, no mesh |
  |  | probes +      |   | (one per run) |                             |
  |  | warm-up       |   +-------+-------+                             |
  |  +-------+-------+           |                                     |
  |          |    in-cluster HTTP (TARGET_URL)                         |
  |          +-----------+-------+                                     |
  |                      v                                             |
  |             +------------------+  WAF-filtered  +---------------+  |
  |             |   Gateway pod    |--------------->| echo backend  |  |
  |             | Envoy +          |                +---------------+  |
  |             | coraza-proxy-wasm|                                   |
  |             +--------+---------+                                   |
  |                      ^                                             |
  |                      | WasmPlugin (SSA) + optional rule poll       |
  |             +--------+---------+                                   |
  |             |   Operator pod   |                                   |
  |             | control plane +  |                                   |
  |             | RuleSetCache     |                                   |
  |             +------------------+                                   |
  |                                                                    |
  |  +--------------------------------------------------------------+  |
  |  | Prometheus + Grafana (optional)                              |  |
  |  |   ServiceMonitor -> operator :8443                           |  |
  |  |   PodMonitor     -> Envoy stats :15090                       |  |
  |  +--------------------------------------------------------------+  |
  +-------------------------------------------------------------------+
```

### Why a Job, and why outside the mesh

The measured load runs as a **one-off Kubernetes Job** rather than a long-lived
`kubectl exec`. Some client↔API-server paths reset multi-minute exec streams at
around 120s with zero bytes in flight, which aborted every run at the default
duration. Polling Job status uses short independent API calls that need no
connection held open for the length of the run.

The Job is annotated `sidecar.istio.io/inject: "false"`, matching the loadgen
Deployment. An injected sidecar would add its own latency and CPU to every
measured request, and would also stop the Job from ever reporting success, since
`istio-proxy` does not exit on its own.

### Rule control flow

```
kubectl apply: RuleSource / RuleData / RuleSet / Engine
      |
      v
RuleSourceReconciler --> validate SecLang --> status: Validated / InvalidRules
      |
      v
RuleSetReconciler --> aggregate + validate --> RuleSetCache (in-memory)
      |
      v
EngineReconciler --> WasmPlugin (SSA) --> Istio injects WASM into Gateway pods
      |
      v
HTTP request --> WASM filter evaluates rules --> allow / block / detect
```

By default the Engine **embeds rules statically** — the least fragile mode and
the correct one for request-hot-path latency. Set `POLL_CACHE=true` to inject
`ruleSetCacheServer` and exercise the cache-poll model instead; that path
requires the operator's cache prerequisites.

### Environment requirements

**The default way to meet them:**

```bash
scripts/prereqs/install-all.sh
```

One command, nothing to set first. It detects the platform, installs what is
missing, and verifies the result. Re-running it is a no-op for anything
already present. Use this unless you have a reason not to.

What it decides for you, and why those are the opinions:

| Piece | Kubernetes | OpenShift |
|---|---|---|
| Gateway API CRDs | installs `GATEWAY_API_VERSION` (v1.4.1) | ships with the cluster; left alone |
| Istio | `istioctl`, **minimal** profile — demo adds telemetry addons that compete for CPU with the proxy under test | a GatewayClass on `openshift.io/gateway-controller/v1`, so the **cluster ingress operator** installs OSSM at the version it pins. A hand-installed control plane there is not the one the gateway follows |
| GatewayClass | `istio` | `openshift-default` |
| Operator | published Helm chart, newest in the index | same, plus `openshift.enabled` and the `openshift-gateway` revision |
| Operator image + CRDs | newest downstream build matching the cluster's architecture, and the CRDs from that build's commit — the chart's image is amd64-only and its CRDs lag | same |

Pin `CORAZA_CHART_VERSION` for anything you intend to report — unpinned, two
runs a week apart may not share an operator. The chart version is no longer the
whole story: `install-operator.sh` prints the chart, the image and the CRD
commit, and a report needs all three. Every other knob has a default in
`lib.sh`.

**What it cannot do for you:**

- **Dedicated node pools** for load generator, Gateway, and backend
- **CPU requests = limits** (guaranteed QoS) to avoid throttling
- Kubernetes **v1.32+** or OpenShift **v4.20+** in the first place
- Local tools: `kubectl` (or `oc`), `envsubst`, `python3`, `curl`; plus `helm`,
  and `istioctl` on Kubernetes
- Optional: Prometheus with retention ≥1h at ≤15s scrape interval

Without the first two you are measuring CPU throttling, and no script can tell.

`scripts/prereqs/check.sh` reports what is still missing.
[docs/prerequisites.md](docs/prerequisites.md) has the per-platform detail and
the manual equivalent of every step, for clusters where you would rather do it
by hand. None of it runs as part of a measurement: installing Istio restarts
the gateway proxy, so it must happen before the session, never inside one.

Other routes, if you prefer them: the [Sail
Operator](https://github.com/istio-ecosystem/sail-operator) for Istio on
non-managed clusters, or the operator's own
[DEVELOPMENT.md](https://github.com/networking-incubator/coraza-kubernetes-operator/blob/main/DEVELOPMENT.md)
for a build-from-source install.

---

## The three axes

A test is three independent choices. Keeping them separate is what makes runs
comparable.

```
scenario (how hard)  x  load profile (request shape)  x  ruleset (which rules)
fixed-500qps            args-heavy                       crs
```

### Scenario — load intensity

Sourced env fragments in `scenarios/`. They set **only** QPS, duration, and
connection count, and say nothing about request shape.

| File | QPS | Duration | Conns | Purpose |
|---|---|---|---|---|
| `fixed-500qps.env` | 500 | 120s | 16 | Primary latency KPI, sub-saturation |
| `low-rate-200qps.env` | 200 | 120s | 16 | Expensive shapes that would saturate the link at 500 |
| `max-throughput.env` | 0 (unthrottled) | 60s | 16 | Find the saturation knee |
| `soak.env` | 300 | 3600s | 16 | Leaks, GC behaviour, drift |
| `fixed-500qps-short.env` | 500 | 60s | 16 | Shorter variant; **not** what the matrix script uses |

Latency from `max-throughput` is not comparable to fixed-rate runs.

### Load profile — request shape

Sourced env fragments in `manifests/load-profiles/`, selected with
`LOAD_PROFILE`. Sourced **after** the scenario, so the profile wins on overlap.
They control `METHOD`, `REQ_PATH`, `CONTENT_TYPE`, `PAYLOAD_FILE`, `PAYLOAD`,
`PAYLOAD_SIZE`, `HEADERS`, and `EXPECT_STATUS`.

The three the matrix uses:

| Profile | Shape | Exercises |
|---|---|---|
| `baseline-get` | `GET /`, no args, no body | Header/URI-phase rules only — the WAF's cheapest path |
| `args-heavy` | `GET /search?…` with 25 query args | The 165 CRS `ARGS` rules, ~25× per-arg work |
| `headers-heavy` | `GET /` with 15 extra headers | Phase-1 `REQUEST_HEADERS` rules |

Nine more exist (`args-light`, `json-1kb`, `json-100kb`, `form-urlencoded`,
`multipart`, `body-1kb`, `body-100kb`, `attack-sqli`, `attack-keyword`) — see
[`manifests/load-profiles/README.md`](manifests/load-profiles/README.md). The
four that post a body from a file need `gen-payloads.sh` and `setup.sh` to have
built the `perf-payloads` ConfigMap first.

**Why shape matters:** CRS evaluates most detection rules **once per argument**.
Of the 563 rules in the generated CRS ruleset, **165 reference `ARGS`** and
**16 reference `REQUEST_BODY`**. A bare `GET /` hands them an empty collection,
so they cost almost nothing. Measuring only `GET /` reports the WAF's **best
case**, not a representative one.

### Ruleset — which rules

Committed under `manifests/rulesets/`, resolved by bare name
(`waf.sh on <name>`) or by path. Rule counts are parsed from the manifests at
report time, not hardcoded.

| Ruleset | Rules | Represents |
|---|---|---|
| `off` | 0 | No Engine attached — the B0 baseline, same Gateway/Envoy path with no WASM filter |
| `minimal` | 1 | Floor: cost of the WASM filter itself |
| `medium` | 30 | Typical hand-written policy |
| `crs` | 563 | OWASP CoreRuleSet 4.7.0 — the dominant latency driver |

`off` is not a ruleset file. `waf.sh off` **deletes the Engine**, so traffic
flows through the identical Gateway path with no filter attached.

### The matrix

`run-comprehensive-tests.sh` runs 3 profiles × 4 rulesets = **12 combinations**,
all at `fixed-500qps`:

```
                    +---------+---------+--------+-----+
                    |   off   | minimal | medium | crs |
+-------------------+---------+---------+--------+-----+
| baseline-get      | Test 1  | Test 2  | Test 3 | T 4 |
+-------------------+---------+---------+--------+-----+
| args-heavy        | Test 5  | Test 6  | Test 7 | T 8 |
+-------------------+---------+---------+--------+-----+
| headers-heavy     | Test 9  | Test 10 | Test 11| T12 |
+-------------------+---------+---------+--------+-----+
```

### Detection-only vs blocking

The matrix rulesets use `SecRuleEngine DetectionOnly` so that **every rule is
evaluated** and nothing short-circuits. This is what makes the comparison
apples-to-apples.

In blocking mode (`SecRuleEngine On`) a request denied at rule 8 never
evaluates rules 9–30, so a 30-rule policy can look *faster* than a 2-rule one.
That is an artifact of early exit, not a real result. Use blocking mode only
when you specifically want the cost of the deny path, via the `attack-*`
profiles, which declare `EXPECT_STATUS=403` and are validated automatically.

---

## Components under test

### Tier 1 — request hot path (latency critical)

| Component | Where | Measurement |
|---|---|---|
| Coraza WASM filter | Gateway pod (Envoy) | Added latency per request |
| Rule evaluation | WASM filter | p50–p99.9 by ruleset size and request shape |
| Istio overhead | Gateway pod | B0 baseline (WAF off) |

### Tier 2 — rule delivery path

| Component | Where | Measurement |
|---|---|---|
| RuleSetCache | Operator pod (:18080) | Cache hit rate, memory usage |
| Poll loop | Gateway WASM | Poll frequency vs freshness |

### Tier 3 — control-plane scalability

| Component | Where | Measurement |
|---|---|---|
| RuleSource reconciler | Operator | Validation time per rule count |
| RuleSet reconciler | Operator | Compilation time, memory usage |
| Engine reconciler | Operator | WasmPlugin apply time |

### Tier 4 — rule-update propagation

| Component | Where | Measurement |
|---|---|---|
| End-to-end freshness | CR update → Gateway enforcement | Total propagation latency |

Tiers 2 and 4 require `POLL_CACHE=true`; the default static-embedded mode
bypasses the cache entirely.

---

## Running tests

### Install the prerequisites

```bash
scripts/prereqs/check.sh         # Gateway API, Istio, WasmPlugin CRD, operator
scripts/prereqs/install-all.sh   # install whatever check.sh reported missing
```

One-time per cluster, and deliberately outside `setup.sh`: installing Istio
restarts the gateway proxy, so it must not happen inside a session.
[docs/prerequisites.md](docs/prerequisites.md) has the per-platform detail.

### Provision the target

```bash
scripts/setup.sh
```

Creates the `waf-perf` namespace, builds the `perf-payloads` ConfigMap from
`manifests/load-profiles/payloads/`, deploys the `echo` backend and `loadgen`
deployment, renders `manifests/gateway.yaml` through `envsubst`, waits for
everything to be ready, and smoke-tests loadgen → gateway. It does **not**
enable the WAF.

Apply the manifests through the scripts, not with raw `kubectl apply`:
`gateway.yaml` and `engine.yaml` contain `envsubst` variables and would be
applied with literal `${ENGINE_NAME}` placeholders.

### Run the canonical comparison

`suite.sh` is the canonical entry point. It measures WAF-off first, then once
per ruleset:

```bash
LOAD_PROFILE=args-heavy scripts/suite.sh scenarios/fixed-500qps.env minimal medium crs
```

For the full 12-cell matrix plus report:

```bash
./run-comprehensive-tests.sh
```

### Single run

```bash
LOAD_PROFILE=baseline-get scripts/run.sh scenarios/fixed-500qps.env waf-crs
```

`run.sh` probes before measuring: a benign `GET /`, an attack `GET /?q=attack`,
and — when `LOAD_PROFILE` is set — one request of the profile's **exact shape**
compared against `EXPECT_STATUS`. A mismatch aborts in about a second rather
than measuring rejected traffic as though it were real work.

### Toggle the WAF manually

```bash
scripts/waf.sh on medium     # apply ruleset + Engine, wait for Ready
scripts/waf.sh off           # delete the Engine (B0 baseline)
scripts/waf.sh status        # show engine, ruleset, rulesource, wasmplugin
```

### Collect server-side metrics

```bash
scripts/collect.sh <start_epoch> <end_epoch> <tag> <scenario>
# or, for a whole suite:
COLLECT=true LOAD_PROFILE=args-heavy scripts/suite.sh scenarios/fixed-500qps.env crs
```

`run.sh` prints `window_utc=<start>..<end>` for exactly this purpose.

`<scenario>` is the result group the run was written under — `fixed-500qps` or
`fixed-500qps+args-heavy` — and it goes into the filename
(`metrics__<scenario>__<tag>__<ts>.jsonl`) because nothing else in a metrics
window says which run it belongs to. Omit it and the file is still written, but
`report.py` skips it rather than attribute another scenario's server-side
numbers to the one being reported.

### Tear down

```bash
scripts/teardown.sh                      # deletes the namespace; results/ is retained
scripts/prereqs/uninstall-operator.sh    # also removes the operator, its RBAC and CRDs
```

`uninstall-operator.sh` leaves Istio and the GatewayClass in place — see
[Uninstalling](docs/prerequisites.md#uninstalling) for why, and for the manual
commands if you want them gone too.

---

## Methodology

`suite.sh` and `run.sh` encode most of this. Preserve it, and enforce the rest
by hand.

1. **Isolate the variable.** Change one dimension per run — ruleset size, body
   size, or RPS. Pin everything else.
2. **Measure B0 (WAF off) first, same session, same environment.** Report WAF
   cost as a delta, never an absolute: absolute latency is not portable across
   clusters. Compute it per percentile, like-for-like, on the median of the
   repeats — `added pN = pN(WAF on) − pN(WAF off)` — in **ms** (felt cost) and
   **% = (on − off) / off** (regression budget).
3. **Trust a gap only when it exceeds run-to-run variance.** A delta smaller
   than the WAF-off spread is noise, not signal. Report the spread alongside
   the median.
4. **Warm up, then measure steady state.** `run.sh` discards a `WARMUP`
   (default 10s) run before the measured one.
5. **Settle after toggling.** After `waf.sh on|off`, wait for Istio to apply or
   remove the WasmPlugin — plus one poll interval (~15s) if the cache is
   enabled. `suite.sh` uses `SETTLE=25s`; `run-comprehensive-tests.sh` uses 30s.
   Never measure inside the settle window. For the baseline this is enforced,
   not advised: `waf.sh off` waits for the WasmPlugin to be withdrawn and exits
   non-zero if it is still attached, and `run.sh` re-checks via `EXPECT_WASM`
   before the load starts.
6. **Confirm the WAF actually ran.** Every measured window must show non-zero
   `coraza_waf_requests_total` and the expected block counts. A bypassed filter
   makes the run invalid, not merely optimistic.
7. **Pin the rule version.** No RuleSet edits during a latency run. A
   `coraza_waf_plugin_loads_total` increment mid-window invalidates it.
8. **Repeat ≥3× per data point** and report median plus variance. The scripts do
   not loop — you must re-invoke them. One run is noise.
9. **Avoid coordinated omission.** Use open-model, constant-throughput load with
   HDR histograms. Fortio qualifies; `-qps` is an open model.
10. **Reject bad runs.** Discard any run with node CPU throttling, elevated
    `error_pct`, or an `ActualQPS` that misses the requested rate (see below).
11. **Correlate planes.** Overlay client latency, Envoy CPU, and cache metrics
    on one time axis to attribute a regression to a component.

### Validity criteria

A run is valid when:

- `error_pct` is 0 — all 2xx, except `attack-*` profiles where 403 is expected
  and counted separately as `blocked_pct`
- `ActualQPS` is within ~5% of the requested rate
- The shape probe returned `EXPECT_STATUS`
- No plugin reload occurred inside the window

**An `ActualQPS` shortfall is itself a result** — it means the system could not
sustain the offered load — but it invalidates the *latency* comparison for that
cell, because the percentiles then describe a different, lighter workload than
the baseline they are compared against. Report it as a throughput finding and
re-run the latency cell at a rate the system can hold.

---

## Results and reporting

### Raw output

Every perf-test run gets its own directory under `results/`, named for the
scenario and the UTC time it started:

```
results/<scenario>-DDMMYYHHMMSS/
├── <scenario>+<profile>__<tag>__<UTC timestamp>.json         # raw fortio
├── <scenario>+<profile>__<tag>__<UTC timestamp>.summary.txt  # parsed line
├── metrics__<scenario>+<profile>__<tag>__<ts>.jsonl          # if COLLECT=true
└── <scenario>-report.html                                    # this run alone
```

```
results/
├── fixed-500qps-311026102345/     # suite.sh, 10:23:45 UTC — baseline + 3 rulesets
├── fixed-500qps-311026110012/     # the repeat an hour later
└── fixed-500qps-report.html       # both runs, medianed
```

One directory per invocation: `suite.sh` puts its baseline and every ruleset
run in one, and `run-comprehensive-tests.sh` puts all twelve cells in one,
because a matrix is a single pass. A bare `run.sh` opens its own. Set `RUN_DIR`
to append to an existing directory instead.

The timestamp is UTC, like every other timestamp the harness writes, so a
directory and the files inside it agree.

Keeping a run together means it can be archived, attached to a ticket or
deleted as a unit, and the same-session baseline is never separated from the
WAF-on runs it is the baseline for. The reporter reads `results/` recursively,
so medians still span every directory — three suite runs are three directories
and three repeats per cell.

Folding the profile into the scenario name within a filename keeps runs with
different request shapes in separate groups so they are never pooled into one
median.

The summary carries `actual_qps`, `count`, `avg/min/max`, `p50…p99.9`,
`ret_codes`, `blocked_pct`, `error_pct`, and the `window_utc` range.

Fortio JSON, abridged:

```json
{
  "DurationHistogram": {
    "Count": 60000,
    "Avg": 0.00347,
    "Percentiles": [
      {"Percentile": 50,   "Value": 0.00280},
      {"Percentile": 95,   "Value": 0.00819},
      {"Percentile": 99,   "Value": 0.01631},
      {"Percentile": 99.9, "Value": 0.03300}
    ]
  },
  "ActualQPS": 500.0,
  "RetCodes": {"200": 60000}
}
```

### The report generator

```
results/**/<scenario>[+<profile>]__<tag>__<ts>.json   (every run directory)
   -> build_cells()      medians across repeats, per (profile, ruleset) cell
   -> reportlib builders cards, matrix, tables, Chart.js data, findings
   -> templates/report-template.html
   -> results/<scenario>-report.html
```

| Piece | Responsibility |
|---|---|
| `scripts/report.py` | Discovery, aggregation, validity, substitution |
| `scripts/reportlib.py` | Every HTML fragment and chart |
| `templates/report-template.html` | Layout, styling, Chart.js wiring |
| `generate-report.py` | Shim that delegates to `scripts/report.py` |

Scenario, load profiles and rulesets all come from the filenames, so the page
covers what ran. Each cell is the **median across its repeats**, not the latest
run, and each WAF cost is a delta against that profile's own `waf-off` column.
Rule counts are parsed from the ruleset manifests; the key findings are
generated from the data rather than written by hand.

Sections: Architecture, Scenario, Profiles, WAF Rulesets, Test Matrix,
Performance Results (7 charts: latency by profile, WAF overhead, latency
distribution, complexity impact, rules efficiency, tail-latency ratio, p95
heatmap), Server-side Summary (only when `collect.sh` metrics exist), and
Findings.

A banner at the top of the page states anything that makes the report
unreportable: a profile with no `waf-off` run, a cell that missed its offered
rate by more than 5%, cells resting on fewer than three repeats, metrics files
that could not be attributed. The same lines are printed on stdout. The page is
written either way — what it must not do is look complete when it is not.

Chart.js is loaded from a CDN, so the charts need network access to render;
every number is already in the page.

### Reading the numbers

Do not quote figures from this README or from any previous run's prose. Regenerate
the report and read the current data. Latency is environment-specific, and the
only portable quantity is the delta against a B0 captured in the same session.

For a quick textual delta without HTML:

```bash
grep -H . results/<scenario>-*/<scenario>*__*.summary.txt
```

Then compute `added pN = pN(waf-*) − pN(waf-off)` on the median of repeats.
Prefer p95/p99; never headline the average.

---

## Metrics and observability

### Data plane (WAF)

Envoy stats port `:15090`, prefix `coraza_waf_*`, scraped by a PodMonitor.

- `coraza_waf_transactions_total` — requests processed
- `coraza_waf_interruptions_total` — blocked requests
- `coraza_waf_transaction_duration_seconds` — rule evaluation time
- `coraza_waf_plugin_loads_total` — a mid-window increment invalidates the run

### Control plane

Operator `:8443`, prefix `coraza_*` plus controller-runtime, scraped by a
ServiceMonitor.

- `controller_runtime_reconcile_total`
- `controller_runtime_reconcile_time_seconds`
- `coraza_ruleset_cache_size_bytes`
- `workqueue_depth` — should drain to 0 at scale

### Load generator

Client-side ground truth, from the fortio JSON: latency percentiles, actual QPS,
status-code distribution, request count.

### Resources

Gateway pods (Envoy + WASM), operator pod, backend pods — CPU, memory, WASM heap
size, and CPU throttle counters.

---

## KPIs and acceptance criteria

Targets are environment-specific; each KPI needs a **baseline capture** and a
**regression threshold** (for example, "p99 added latency must not rise more
than 10% against the previous release baseline") before this harness can gate CI.

- **Added latency (WAF on − WAF off)** at fixed RPS, p95 and p99 — *primary*
- **Throughput retention:** max RPS with CRS ÷ max RPS at B0
- **Latency vs body size** slope — ms per additional KB scanned
- **Cache poll latency** p99 under target pod × engine fan-out
- **Rule-update propagation** p95 — should approach `pollIntervalSeconds`
- **Control plane:** RuleSet compile p95 for CRS; reconcile queue drains
- **Stability:** no WASM VM or cache memory growth over a 4h soak; zero
  unexpected plugin loads or `outcome="error"`

---

## Confounders and risks

- **CPU throttling** on Gateway, backend, or load generator — the single largest
  source of bogus latency spikes. Pin CPU, use guaranteed QoS, watch throttle
  counters.
- **Coordinated omission** in the load tool hides tail latency. Use open-model
  generators.
- **Backend as the bottleneck.** It is a trivially fast, over-provisioned echo
  so it never gates. If it saturates you are measuring the app, not the WAF.
- **Load generator saturation** — verify the client's own CPU is not the limit.
- **Rule reloads or cache eviction mid-run** invalidate the window; assert none.
- **WASM VM warm-up** — discard it, and keep it consistent across runs.
- **Noisy neighbours** on shared nodes — dedicate and pin node pools.
- **Network path variance** — keep the generator in-cluster or on a fixed link.

---

## Configuration knobs

Environment variables; defaults in `lib.sh`.

| Var | Default | Meaning |
|---|---|---|
| `PLATFORM` | `kubernetes` | `kubernetes` or `openshift` — selects CLI and GatewayClass |
| `CLI` | `kubectl` / `oc` | Cluster CLI, derived from `PLATFORM` |
| `NAMESPACE` | `waf-perf` | Test namespace |
| `GATEWAY_NAME` | `perf-gateway` | Gateway name |
| `GATEWAY_CLASS` | `istio` / `openshift-default` | GatewayClass, derived from `PLATFORM` |
| `ENGINE_NAME` | `perf-engine` | Engine name |
| `RULESET_NAME` | `perf-ruleset` | RuleSet the Engine attaches to |
| `TARGET_URL` | in-cluster gateway svc | What the generator hits |
| `LOADGEN_IMAGE` | `fortio/fortio:latest` | Load generator image |
| `WARMUP` | `10s` | Discarded warm-up per run |
| `SETTLE` | `25s` | Post-toggle wait (`suite.sh`) |
| `COLLECT` | `false` | Also pull Prometheus metrics per run |
| `FAILURE_POLICY` | `fail` | Engine failure policy (`fail` or `allow`) |
| `POLL_CACHE` | `false` | Inject `ruleSetCacheServer` (cache-poll model) |
| `POLL_INTERVAL_SECONDS` | `15` | Poll cadence when `POLL_CACHE=true` |
| `EXPECT_STATUS` | `200` | Status the shape probe must see |
| `EXPECT_BLOCK` | unset | Assert the attack probe is (`true`) or isn't (`false`) blocked |
| `EXPECT_BENIGN_STATUS` | unset | Assert the benign probe's status |
| `EXPECT_WASM` | unset | Assert a WasmPlugin is (`true`) or isn't (`false`) attached; `suite.sh` sets `false` on the baseline |
| `WAIT_TIMEOUT` | `180s` | Readiness wait timeout |
| `WASM_WAIT_TIMEOUT` | `60` | Seconds `waf.sh off` waits for the WasmPlugin to be withdrawn |
| `CORAZA_IMAGE_REPO` / `CORAZA_IMAGE_TAG` | chart default | Operator image; override for a locally built one |
| `CORAZA_CRD_DIR` | chart's `crds/` | CRD source. Set it to `<operator-checkout>/config/crd/bases` whenever `CORAZA_IMAGE_REPO` is set — image and CRDs must come from the same revision |
| `RESULTS_DIR` | `./results` | Where results are written |
| `PROM_NAMESPACE` / `PROM_SVC` / `PROM_PORT` | `monitoring` / `prometheus-k8s` / `9090` | Prometheus location |

Scenario files set `QPS`, `DURATION`, and `CONNS`. Profiles set `METHOD`,
`REQ_PATH`, `CONTENT_TYPE`, `PAYLOAD_FILE`, `PAYLOAD`, `PAYLOAD_SIZE`,
`HEADERS`, and `EXPECT_STATUS`.

Operator-side knobs that move the numbers: ruleset size and CRS paranoia level
(dominant), `SecRequestBodyAccess` / `SecResponseBodyAccess`,
`pollIntervalSeconds`, `failurePolicy`, Gateway replicas and CPU limits,
`--cache-max-size` / `--cache-max-age` / `--cache-gc-interval`, and the WASM
image.

---

## Customization

### New load profile

```bash
cp manifests/load-profiles/baseline-get.env manifests/load-profiles/my-profile.env
```

Edit the shape, then use it with `LOAD_PROFILE=my-profile`. The report picks it
up on its own — profiles are discovered from the result filenames — and
describes it from its `.env` when it has no curated description.

A profile that needs a body file also needs `gen-payloads.sh` and a re-run of
`setup.sh` so the payload lands in the ConfigMap — and see
[known limitations](#known-limitations).

### New ruleset

```bash
cp manifests/rulesets/minimal.yaml manifests/rulesets/my-ruleset.yaml
```

Use it with `waf.sh on my-ruleset`. The report discovers it from the result
filenames and counts its rules from `manifests/rulesets/my-ruleset.yaml`. Add
an entry to `RULESETS` in `scripts/reportlib.py` only if you want curated
wording on its card instead of the generic descriptor.

### New scenario

Copy any file in `scenarios/` and set `QPS`, `DURATION`, `CONNS`. The HTML
report needs no change — it keys off the scenario in the result filenames and
writes `results/<scenario>-report.html`. `analyze-results.py` is still
hardcoded to `fixed-500qps`; see [known limitations](#known-limitations).

### Regenerating CRS

Only needed to bump the CRS version. `kubectl coraza` is built from the operator
repo, not this one — download a `kubectl-coraza` binary from the
[operator's releases](https://github.com/networking-incubator/coraza-kubernetes-operator/releases)
(cut by its `release.kubectl-plugin` target) and put it on your `PATH` first.

```bash
curl -sL https://github.com/coreruleset/coreruleset/archive/refs/tags/v4.7.0.tar.gz | tar -xz -C /tmp
kubectl coraza generate coreruleset \
  --rules-dir /tmp/coreruleset-4.7.0/rules --version 4.7.0 \
  --ruleset-name perf-ruleset \
  --ignore-unsupported-rules wasm \
  --ignore-rules 920420 \
  > manifests/rulesets/crs.yaml
```

Two things are hand-added to the generated file and must be re-added afterwards,
both explained in its header comment:

- the `skip-unsupported-rules-check` annotation on the RuleSet (CRS 980170)
- `--ignore-rules 920420` — under coraza-proxy-wasm that rule rejects **every**
  request carrying a `Content-Type`, so all POST traffic 403s, even when the
  content type is in the allowlist

### New chart

Add a `<canvas id="myChart">` to `templates/report-template.html`, build the
config in `prepare_chart_data()`, return it under a `myChart` key, and
initialize it in the template.

---

## Known limitations

- **The matrix is a single repeat per cell.** The methodology calls for ≥3.
  `run-comprehensive-tests.sh` runs each combination once and says so in its
  banner, so its output is indicative, not reportable, until you re-run it and
  take medians.
- **`PAYLOAD_FILE` profiles need the ConfigMap in place.** The measured-run Job
  mounts `perf-payloads` at `/payloads`, matching the loadgen pod, but the mount
  is `optional` — so a profile whose payload was never built would send an empty
  body. `run.sh` guards against this by checking the key exists in the ConfigMap
  before measuring, and aborts with the `gen-payloads.sh` + `setup.sh` fix.
- **`analyze-results.py` is hardcoded to the `fixed-500qps` scenario** and to
  its own ruleset labels, so its text tables describe that scenario whatever
  you ran, and silently find nothing under another name. The HTML report no
  longer shares this: it discovers scenario, profiles and rulesets from the
  result filenames.
- **The report can only name the cluster you tell it about.** Nothing in
  `results/` records the platform, Istio or operator version, so they come from
  `PLATFORM`, `ISTIO_VERSION` and `OPERATOR_VERSION` and render as "not
  recorded" when unset. This replaced a set of literals that asserted the
  author's cluster on every report; a blank is recoverable, a confident wrong
  version is not. Fortio's version is read from the result JSON.
- **The fortio image is unpinned.** The default is still `fortio/fortio:latest`,
  which sits badly with the Fortio v1.76+ line in [Dependencies](#dependencies)
  — two sessions weeks apart may not have measured with the same load
  generator. `manifests/loadgen.yaml` now reads `LOADGEN_IMAGE` rather than
  carrying its own copy of the tag, so setting that one variable to a tagged
  release is enough to make runs comparable over time.

---

## Troubleshooting

### Missing data in the report

```bash
ls -1 results/fixed-500qps+*.json | wc -l      # expect 12+
ls -lh results/fixed-500qps+*.json             # empty files are skipped
python3 -m json.tool results/fixed-500qps+baseline-get__waf-off__*.json | head
```

### Unexpected 403s

The matrix expects 0% errors. 403s mean the WAF is blocking rather than
detecting:

```bash
grep "SecRuleEngine" manifests/rulesets/*.yaml   # expect DetectionOnly
kubectl get rulesets -n waf-perf -o yaml
scripts/waf.sh status
```

For `attack-*` profiles 403 is the expected status and is reported as
`blocked_pct`, not `error_pct`.

### Run aborts on the shape probe

The profile's own request shape returned something other than `EXPECT_STATUS`.
Either the WAF is blocking that shape — CRS 920420 against any `Content-Type`
is the usual culprit — or the target is misconfigured. Set `EXPECT_STATUS` in
the profile if the status is intended.

### Run aborts: Job did not complete

The measured-run Job exceeded `DURATION + 90s`:

```bash
kubectl logs -n waf-perf job/<job-name>
kubectl get pods -n waf-perf
```

### Pods not ready

```bash
kubectl get pods -n waf-perf
kubectl logs -n waf-perf deployment/loadgen
kubectl logs -n waf-perf deployment/echo
```

The backend deployment is named `echo`, not `backend`.

### Payload missing from the ConfigMap

```bash
manifests/load-profiles/gen-payloads.sh && scripts/setup.sh
```

### Inconsistent results across runs

Usually CPU throttling, network variance, or noisy neighbours. Pin Gateway pods
to dedicated nodes, set CPU requests equal to limits, and run ≥3 iterations
taking the median with spread. Warm-up is already handled by `run.sh`.

### Report generation fails

```bash
python3 -u scripts/report.py 2>&1 | tee report-gen.log
python3 --version                      # 3.8+
ls -l templates/report-template.html scripts/reportlib.py
```

---

## File structure

```
waf-perf-test/
├── README.md                     # this file
├── CLAUDE.md                     # agent contract: guardrails + routing
├── LICENSE                       # Apache-2.0
├── NOTICE                        # vendored CoreRuleSet attribution
├── lib.sh                        # shared config + helpers (sourced, not run)
├── run-comprehensive-tests.sh    # the 12-cell matrix + report
├── generate-report.py            # shim -> scripts/report.py
├── analyze-results.py            # data analysis helper
├── requirements.txt              # PyYAML, for rule counts (optional)
├── scripts/
│   ├── prereqs/                  # one-time cluster install: Istio, CRDs, operator
│   │   ├── check.sh              # verify prerequisites, fail fast
│   │   ├── install-all.sh        # the three installers, in order, then check
│   │   ├── install-gateway-api.sh
│   │   ├── install-istio.sh
│   │   ├── install-operator.sh
│   │   ├── resolve-operator-image.sh  # pick a build matching the cluster's arch
│   │   └── uninstall-operator.sh
│   ├── setup.sh                  # provision namespace, backend, loadgen, gateway
│   ├── waf.sh                    # on <ruleset> | off | status
│   ├── run.sh                    # one measured run with validity probes
│   ├── suite.sh                  # B0 + one run per ruleset (canonical)
│   ├── collect.sh                # pull Prometheus metrics for a window
│   ├── report.py                 # per-scenario report, delta vs B0
│   ├── reportlib.py              # HTML fragments and Chart.js data
│   └── teardown.sh
├── scenarios/                    # QPS / duration / connections
├── manifests/
│   ├── backend.yaml              # echo backend
│   ├── loadgen.yaml              # fortio deployment
│   ├── gateway.yaml              # Gateway + HTTPRoute (envsubst)
│   ├── engine.yaml               # Engine (envsubst)
│   ├── rulesets/                 # minimal, medium, crs
│   └── load-profiles/            # request shapes + payloads + README
├── templates/
│   └── report-template.html      # matrix report template
├── testdata/
│   └── sample-results/           # report-generator fixture (another cluster)
├── .claude/
│   └── skills/perf-test/         # agent skill for driving this harness
├── docs/
│   ├── prerequisites.md          # cluster prerequisites and their installers
│   └── plans/                    # planning artifacts
└── results/                      # raw JSON, summaries, generated HTML (ignored)
```

---

## License

This project is licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE) for the full text.

The vendored OWASP CoreRuleSet content in `manifests/rulesets/crs.yaml` is redistributed under its original Apache-2.0 license. See [`NOTICE`](NOTICE) for attribution.

---

## References

### Dependencies

Python 3.8+ and a modern browser for reports. PyYAML is optional: the report
uses it to count rules in `manifests/rulesets/*.yaml`, and falls back to known
counts with a warning when it is missing. It is pinned in `requirements.txt`:

```bash
pip install -r requirements.txt
```

For runs: Kubernetes v1.32+ or OpenShift v4.20+, Istio v1.27+, Fortio v1.76+,
and coraza-kubernetes-operator v0.5.0+. Prometheus and Grafana are optional.

### Related docs

| Topic | Doc |
|---|---|
| Load profile details | `manifests/load-profiles/README.md` |
| Agent contract: guardrails and routing | `CLAUDE.md` |
| Driving this harness as an agent | `.claude/skills/perf-test/SKILL.md` |
| Cluster and Istio setup | [operator `DEVELOPMENT.md`](https://github.com/networking-incubator/coraza-kubernetes-operator/blob/main/DEVELOPMENT.md) |
| Two-plane split, metric contract | [operator `docs/driver-metrics-contract.md`](https://github.com/networking-incubator/coraza-kubernetes-operator/blob/main/docs/driver-metrics-contract.md) |
| Controllers, cache server, Istio prerequisites | [operator `docs/content/explanation/architecture.md`](https://github.com/networking-incubator/coraza-kubernetes-operator/blob/main/docs/content/explanation/architecture.md) |
| WASM integration, poll loop, target selection | [operator `docs/content/explanation/istio-wasm-integration.md`](https://github.com/networking-incubator/coraza-kubernetes-operator/blob/main/docs/content/explanation/istio-wasm-integration.md) |
| Rule aggregation and validation lifecycle | [operator `docs/content/explanation/rule-processing.md`](https://github.com/networking-incubator/coraza-kubernetes-operator/blob/main/docs/content/explanation/rule-processing.md) |
| Operator metrics and cardinality | [operator `docs/content/reference/metrics-cardinality.md`](https://github.com/networking-incubator/coraza-kubernetes-operator/blob/main/docs/content/reference/metrics-cardinality.md) |
| CLI flags and cache tuning | [operator `docs/content/reference/operator-cli-flags.md`](https://github.com/networking-incubator/coraza-kubernetes-operator/blob/main/docs/content/reference/operator-cli-flags.md) |

### External links

- [Fortio](https://github.com/fortio/fortio)
- [Chart.js](https://www.chartjs.org/docs/)
- [Coraza WAF](https://coraza.io/)
- [OWASP CoreRuleSet](https://coreruleset.org/)
- [Istio performance and scalability](https://istio.io/latest/docs/ops/deployment/performance-and-scalability/)
- [SecRuleEngine directive](https://coraza.io/docs/seclang/directives/#secruleengine)
