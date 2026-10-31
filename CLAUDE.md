# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## What this repo is

A performance-testing harness for the [Coraza Kubernetes Operator](https://github.com/networking-incubator/coraza-kubernetes-operator). It measures what the WAF actually costs: the `coraza-proxy-wasm` module running inside the Envoy proxy of a Gateway pod, driven by fortio from inside the cluster.

It is a test harness, not a product. Nothing here is deployed; there is no Go code, no build, and no CI. The work is bash, Python, and Kubernetes manifests.

**The number this harness produces is never an absolute latency.** It is the delta against a WAF-off baseline captured in the same session. Absolute latency is a property of the cluster it ran on and does not travel.

## The guardrails

These are not style preferences. Violating one does not make a run slightly worse; it makes the number wrong while still looking plausible. `README.md` explains the reasoning behind each in [Methodology](README.md#methodology) — read it before you decide to deviate.

1. **Capture the WAF-off baseline in the same session, before any WAF-on run.** `scripts/suite.sh` does this for you. Report the delta per percentile, never an absolute.
2. **Change one axis per run.** The three axes are load intensity, request shape, and ruleset size. Pin the other two.
3. **Wait out the settle window after toggling the WAF.** `suite.sh` waits 25 seconds; `run-comprehensive-tests.sh` waits 30. Never measure inside it.
4. **Let the warm-up be discarded.** `scripts/run.sh` throws away a 10-second run before the measured one.
5. **Repeat at least three times per data point** and report the median with its spread. None of the scripts loop, so this is on you: invoke the suite again. One run is noise.
6. **Confirm the filter actually ran.** A bypassed WAF produces a fast, clean, meaningless number.
7. **Prefer p95 and p99. Never headline the average.**

## When to throw a run away

A run is valid only when all of these hold, per [Validity criteria](README.md#validity-criteria):

- `error_pct` is 0, except on `attack-*` profiles where 403 is expected and counted as `blocked_pct`.
- `ActualQPS` is within about 5% of the requested rate.
- The shape probe returned the profile's `EXPECT_STATUS`.
- No plugin reload happened inside the measurement window.

An `ActualQPS` shortfall is itself a finding — the system could not hold the offered load — but it invalidates the latency comparison for that cell, because the percentiles then describe a lighter workload than the baseline they are compared against.

## Entry points

All scripts resolve their own paths, so they work when invoked from anywhere.

```bash
scripts/prereqs/check.sh              # verify cluster prerequisites; run before setup.sh
scripts/prereqs/install-all.sh        # one-time: Gateway API, Istio, operator
scripts/setup.sh                      # provision namespace, backend, loadgen, Gateway, payloads
scripts/waf.sh on <minimal|medium|crs>  # or: off | status
scripts/suite.sh <scenario-file> [rulesets...]   # canonical: baseline then one run per ruleset
scripts/run.sh <scenario-file> [tag]  # one measured run with validity probes
scripts/collect.sh <start> <end> [tag] [scenario]  # pull Prometheus metrics for a window
scripts/teardown.sh                   # delete the namespace; results are kept
scripts/prereqs/uninstall-operator.sh # also remove the operator, its RBAC and CRDs
```

Reporting needs no cluster:

```bash
pip install -r requirements.txt               # PyYAML, for rule counts; optional
python3 scripts/report.py                     # one page per scenario in results/
python3 scripts/report.py --scenario fixed-500qps   # just that one
```

`scripts/report.py` is the only report generator. One page per scenario, covering every load profile measured under it as a profiles × rulesets matrix, every figure the median across that cell's repeats, every WAF cost a delta against that profile's own `waf-off` baseline. It discovers the scenario, the profiles and the rulesets from the filenames under `results/`, searched recursively, so it reports what ran rather than what was configured. Output is `results/<scenario>-report.html`; point `--results` at one run directory to report on that session alone.

Rendering lives in `scripts/reportlib.py` and `templates/report-template.html`; `generate-report.py` is a shim that delegates, kept so older commands still work. Cluster facts the results cannot carry — `PLATFORM`, `ISTIO_VERSION`, `OPERATOR_VERSION`, `NAMESPACE` — are read from the environment and render as "not recorded" when unset.

For a guided run, the bundled skill at `.claude/skills/perf-test/SKILL.md` carries the correct ordering and the delta analysis. It defers to this file where the two disagree.

## Prerequisites

A measurement run installs nothing. The cluster-side pieces are installed once,
beforehand, by `scripts/prereqs/install-all.sh` — never from `setup.sh` or
during a session, because installing Istio restarts the gateway proxy and
breaks the same-session baseline. That script is the default route and takes
no arguments; `scripts/prereqs/check.sh` reports what is missing;
`docs/prerequisites.md` explains each piece and its manual equivalent.

- A Kubernetes v1.32+ or OpenShift v4.20+ cluster with Istio and the Gateway API CRDs.
  On OpenShift, Istio is installed by the cluster ingress operator in response to a
  GatewayClass — do not install a second control plane by hand.
- The Coraza Kubernetes Operator, from its published Helm chart. Pin
  `CORAZA_CHART_VERSION` for anything reportable. The chart supplies the
  deployment only. Its ghcr.io image is amd64-only, so `install-operator.sh`
  resolves one from the multi-arch Konflux stream instead, and takes the CRDs
  from that build's commit — the chart's are pinned to the chart version and a
  newer operator needs fields they do not define. Konflux is staging (SHA tags,
  no `latest`, collected builds): it gets a cluster working, it does not pin a
  reported number, which is why the installer prints the resolved image digest.
  Record chart version, image digest and CRD commit together. `CORAZA_IMAGE_REPO`
  with `CORAZA_CRD_DIR` overrides both halves for a build of your own.
- Local tools: `kubectl` or `oc`, `envsubst`, `python3`, `curl`; plus `helm` and,
  on Kubernetes, `istioctl` for the prereq scripts.
- `PLATFORM` is detected from the cluster when unset, and drives both the CLI and
  the gateway class. Set it only to override a correct detection; an override that
  disagrees with the cluster warns rather than fails, since doing it deliberately
  is legitimate.
- For metrics collection, a reachable Prometheus with the operator's ServiceMonitor and PodMonitor enabled.
- Dedicated node pools and guaranteed QoS for the load generator, Gateway, and backend. Without them you are measuring CPU throttling.

## Defects that will mislead you

Carried over from the harness's previous home and deliberately not fixed, so the port stays faithful. [Known limitations](README.md#known-limitations) has the full list with line references.

- **The matrix is one repeat per cell.** `run-comprehensive-tests.sh` runs each combination once, which the methodology says is not reportable. Its output is indicative only — the report now says so per cell, but the script still only runs one pass. Invoke it again, or `suite.sh` per profile, and regenerate: results accumulate and the medians widen.
- **The load generator image is unpinned.** `LOADGEN_IMAGE` still defaults to `fortio/fortio:latest`, so runs weeks apart may not share a load generator. The manifest no longer carries a second copy of the tag — it reads the variable — so pinning it in one place is now enough. The report states the fortio version it finds in the results.
- **`analyze-results.py` still carries its own `fixed-500qps` glob** and its own ruleset labels, so its text tables describe that scenario whatever you ran. The HTML report no longer does: it discovers scenario, profiles and rulesets from the filenames.

Fixed here, and worth knowing if you compare against an older report: the HTML no longer hardcodes the author's cluster (OpenShift 4.22.18, Istio v1.27.5, operator v0.5.0, Fortio 1.76.0) — those are environment variables now, blank unless set — and it no longer takes the latest single run per cell.

## Conventions

- Shell scripts are `set -euo pipefail` and source `lib.sh` for shared config. Every tunable is an environment variable with a default in `lib.sh`; add new ones there rather than inline.
- Comments in these scripts frequently record why a past approach failed. Preserve them when editing.
- **Every run gets its own directory**: `results/<scenario>-DDMMYYHHMMSS/`, UTC, created by `suite.sh` (one per invocation) or `run-comprehensive-tests.sh` (one per matrix). `run.sh` honours `RUN_DIR` when set and opens its own when not; `collect.sh` writes its metrics into the same one. `lib.sh:new_run_dir` is the only place the name is built. Raw JSON, summaries, metrics and that run's own report live together, so a run archives or deletes as a unit and a same-session baseline is never separated from the runs it baselines. The reporter reads `results/` recursively, which is what keeps medians spanning repeats.
- `results/` is ignored. Fixture data for exercising the report generator lives in `testdata/sample-results/` and was measured on another cluster; no number in it is reportable here. Never copy it into `results/`: the report medians every run it finds for a cell, so a fixture left there silently averages another cluster into the delta. To render it, point the generator at it instead — `scripts/report.py --results testdata/sample-results --out /tmp/x.html`.
- Do not quote figures from `README.md` or any previous run. Regenerate the report and read the current data.
