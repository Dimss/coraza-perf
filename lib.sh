#!/usr/bin/env bash
#
# lib.sh - shared config + helpers for the Coraza WAF performance-testing harness.
# Sourced by the scripts under scripts/; not meant to be run directly.
#
set -euo pipefail

# --- paths ------------------------------------------------------------------
PT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${PT_ROOT}/manifests"
RULESETS_DIR="${MANIFESTS_DIR}/rulesets"
LOAD_PROFILES_DIR="${MANIFESTS_DIR}/load-profiles"
PAYLOADS_DIR="${LOAD_PROFILES_DIR}/payloads"
PAYLOADS_CONFIGMAP="${PAYLOADS_CONFIGMAP:-perf-payloads}"
SCENARIOS_DIR="${PT_ROOT}/scenarios"
RESULTS_DIR="${RESULTS_DIR:-${PT_ROOT}/results}"

# One sub-directory per perf-test run: results/<scenario>-DDMMYYHHMMSS. Raw
# fortio JSON, summaries, collected metrics and that run's own report all land
# together, so a run can be archived or deleted as a unit. The reporter reads
# results/ recursively, so medians across repeats still span every run folder.
#
# suite.sh creates one and exports RUN_DIR; run.sh honours it, and makes its
# own when invoked directly. Set RUN_DIR yourself to append to an existing one.
new_run_dir() {
  local scenario="${1:?new_run_dir <scenario-name>}"
  printf '%s/%s-%s' "${RESULTS_DIR}" "${scenario}" "$(date -u +%d%m%y%H%M%S)"
}

# --- platform / cluster -----------------------------------------------------
# Unset means "ask the cluster". PLATFORM decides both the CLI and the gateway
# class, and defaulting it blindly to kubernetes on an OpenShift cluster aimed
# setup.sh at a GatewayClass that does not exist there — which surfaced as a
# hang on the Gateway readiness wait, not an error. Set it explicitly to
# override (e.g. PLATFORM=kubernetes on OpenShift when Istio was installed by
# hand rather than by the cluster ingress operator).
PLATFORM_DETECTED=false
if [[ -z "${PLATFORM:-}" ]]; then
  _probe="$(command -v oc || command -v kubectl || true)"
  if [[ -n "${_probe}" ]] && \
     "${_probe}" api-resources --api-group=route.openshift.io 2>/dev/null | grep -q "routes"; then
    PLATFORM=openshift
  fi
  PLATFORM="${PLATFORM:-kubernetes}"
  PLATFORM_DETECTED=true
  unset _probe
fi
case "${PLATFORM}" in
  kubernetes|k8s) PLATFORM="kubernetes"; CLI="${CLI:-kubectl}"; GATEWAY_CLASS="${GATEWAY_CLASS:-istio}";;
  openshift|ocp)  PLATFORM="openshift";  CLI="${CLI:-oc}";      GATEWAY_CLASS="${GATEWAY_CLASS:-openshift-default}";;
  *) echo "ERROR: unknown PLATFORM='${PLATFORM}'" >&2; exit 1;;
esac

# --- test topology ----------------------------------------------------------
NAMESPACE="${NAMESPACE:-waf-perf}"
GATEWAY_NAME="${GATEWAY_NAME:-perf-gateway}"
GATEWAY_SVC="${GATEWAY_SVC:-${GATEWAY_NAME}-${GATEWAY_CLASS}}"
# In-cluster URL the load generator hits (keeps client<->gateway hop internal).
TARGET_URL="${TARGET_URL:-http://${GATEWAY_SVC}.${NAMESPACE}.svc.cluster.local:80}"

# Load generator (fortio: open-model, HDR histograms -> no coordinated omission).
LOADGEN_IMAGE="${LOADGEN_IMAGE:-fortio/fortio:latest}"
LOADGEN_NAME="${LOADGEN_NAME:-loadgen}"

# Pod sizing. The defaults deliberately over-provision: the backend must never
# be the bottleneck, or the number describes the backend and not the WAF.
# Lower them only to exercise the harness on a cluster that cannot fit the
# defaults (CRC, kind). Any run made with reduced sizing is a smoke test, not a
# measurement — it is the throttling these values exist to avoid.
BACKEND_REPLICAS="${BACKEND_REPLICAS:-3}"
BACKEND_CPU_REQUEST="${BACKEND_CPU_REQUEST:-1}"
BACKEND_CPU_LIMIT="${BACKEND_CPU_LIMIT:-2}"
BACKEND_MEM_REQUEST="${BACKEND_MEM_REQUEST:-256Mi}"
BACKEND_MEM_LIMIT="${BACKEND_MEM_LIMIT:-512Mi}"
LOADGEN_CPU_REQUEST="${LOADGEN_CPU_REQUEST:-2}"
LOADGEN_CPU_LIMIT="${LOADGEN_CPU_LIMIT:-4}"
LOADGEN_MEM_REQUEST="${LOADGEN_MEM_REQUEST:-512Mi}"
LOADGEN_MEM_LIMIT="${LOADGEN_MEM_LIMIT:-1Gi}"

# WAF resource names.
ENGINE_NAME="${ENGINE_NAME:-perf-engine}"
RULESET_NAME="${RULESET_NAME:-perf-ruleset}"

# Observability (optional metric collection via collect.sh).
PROM_NAMESPACE="${PROM_NAMESPACE:-monitoring}"
PROM_SVC="${PROM_SVC:-prometheus-k8s}"
PROM_PORT="${PROM_PORT:-9090}"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-180s}"
# How long waf.sh waits for the operator to withdraw the WasmPlugin after the
# Engine is deleted. Separate from WAIT_TIMEOUT because this one gates a
# measurement rather than a provisioning step: it should fail fast and loudly
# rather than sit for three minutes.
WASM_WAIT_TIMEOUT="${WASM_WAIT_TIMEOUT:-60}"

# --- prerequisites (scripts/prereqs/ only) ----------------------------------
# Read only by scripts/prereqs/*.sh. A measurement run never installs anything:
# keeping the installers out of setup.sh is what stops a cluster change from
# landing inside a measurement window. See docs/prerequisites.md.
#
# Gateway API CRDs. OpenShift ships its own set and the version below is
# ignored there; overriding it on OpenShift would fight the ingress operator.
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.1}"
# Upstream Istio, Kubernetes only. Default tracks the version OpenShift 4.22
# installs for its managed Gateway API, so the two platforms stay comparable.
ISTIO_VERSION="${ISTIO_VERSION:-1.28.5}"
# minimal, not demo: the demo profile adds telemetry addons that compete for
# CPU with the proxy under test.
ISTIO_PROFILE="${ISTIO_PROFILE:-minimal}"
# OpenShift: creating a GatewayClass with this controller is what makes the
# cluster ingress operator install OSSM and an Istio control plane for it.
OCP_GATEWAY_CONTROLLER="${OCP_GATEWAY_CONTROLLER:-openshift.io/gateway-controller/v1}"
# The Istio revision the OpenShift ingress operator names its control plane.
# The operator chart must target the same revision or the WasmPlugin it writes
# is ignored by the gateway's proxy.
OCP_ISTIO_REVISION="${OCP_ISTIO_REVISION:-openshift-gateway}"

# Coraza operator Helm chart, published by the operator repo's release CI.
CORAZA_CHART_REPO="${CORAZA_CHART_REPO:-https://networking-incubator.github.io/coraza-kubernetes-operator/}"
CORAZA_CHART_REPO_NAME="${CORAZA_CHART_REPO_NAME:-coraza-kubernetes-operator}"
CORAZA_CHART="${CORAZA_CHART:-coraza-kubernetes-operator/coraza-kubernetes-operator}"
# Empty means "newest in the repo index". Pin it for a reportable run: the
# operator version is part of what the number describes.
CORAZA_CHART_VERSION="${CORAZA_CHART_VERSION:-}"
CORAZA_NAMESPACE="${CORAZA_NAMESPACE:-coraza-system}"
CORAZA_RELEASE="${CORAZA_RELEASE:-coraza-kubernetes-operator}"
# Operator image. Empty no longer means "whatever the chart defaults to":
# install-operator.sh resolves one instead, because the chart's ghcr.io release
# images are linux/amd64 only — every tag through v0.5.0 is a single-platform
# index — and on an arm64 cluster (CRC on Apple Silicon) the pod never starts,
# failing with "no image found in image index for architecture arm64".
#
# Set these to run a build of your own, which also opts out of the resolution.
# Set CORAZA_CRD_DIR with them: once the image is not the chart's, the chart's
# CRDs are not the matching ones either.
CORAZA_IMAGE_REPO="${CORAZA_IMAGE_REPO:-}"
CORAZA_IMAGE_TAG="${CORAZA_IMAGE_TAG:-}"
# Where resolve-operator-image.sh looks. The Konflux push builds here are
# multi-arch, which is the one thing the chart's image is not. It is a staging
# registry, not a release channel: tags are commit SHAs, there is no 'latest',
# builds are garbage-collected, and the images carry no version label. It gets
# a cluster working; it does not pin a reported number, which is why the
# installer reads back the resolved digest at the end.
CORAZA_QUAY_REPO="${CORAZA_QUAY_REPO:-redhat-user-workloads-stage/waf-tenant/waf-0-7/waf-operator}"
# Git repo behind those builds. Each image is tagged with its commit here, and
# that commit carries the CRDs the image expects, so the two are pinned
# together rather than hoping the chart's are current.
CORAZA_BUILD_REPO="${CORAZA_BUILD_REPO:-networking-incubator/build-waf}"
CORAZA_BUILD_CRD_PATH="${CORAZA_BUILD_CRD_PATH:-images/bundle/manifests}"
# The CSV in that same bundle directory. Its clusterPermissions are the RBAC
# the image expects, which the chart's ClusterRole is not: the chart pins its
# rules to the chart version exactly as it pins its CRDs, and a manager from a
# newer release line watches resources those rules do not grant.
CORAZA_BUNDLE_CSV="${CORAZA_BUNDLE_CSV:-coraza-kubernetes-operator.clusterserviceversion.yaml}"
# How long to wait for the operator Deployment to go Available. This is ours
# rather than helm's --wait: the RBAC has to be corrected after helm creates
# the ClusterRole, so helm must not block on a manager that cannot start yet.
CORAZA_WAIT_TIMEOUT="${CORAZA_WAIT_TIMEOUT:-300s}"
# Commit in CORAZA_BUILD_REPO to take CRDs from. Empty means "whatever image
# was resolved", and it is set for you. Set it by hand only when overriding the
# image with a build whose tag means nothing in that repo.
CORAZA_CRD_REF="${CORAZA_CRD_REF:-}"
# A local directory of CRDs, which beats both of the above. Use it with a build
# of your own: point it at config/crd/bases in the checkout the image came from.
#
# Why the pairing matters at all. The chart's CRDs are pinned to the chart
# version, the image is not, and a build newer than the chart needs fields the
# chart has never heard of. Chart 0.5.0 ships rulesources and ruledata with no
# status subresource, so a newer operator writes RuleSource status into an
# endpoint the API server does not serve and every patch comes back "not
# found" — naming the object, not the schema. The RuleSet then waits on a
# validation that can never arrive and waf.sh times out on
# 'oc wait ruleset --for=condition=Ready'. See docs/prerequisites.md.
CORAZA_CRD_DIR="${CORAZA_CRD_DIR:-}"

# Set by require_prereqs once scripts/prereqs/check.sh has passed, so a wrapper
# that already ran it does not repeat the whole report before each inner
# invocation (run-comprehensive-tests.sh calls suite.sh once per profile).
# Setting it in the environment by hand skips the gate — the escape hatch for
# an operator deployed some other way, e.g. 'make deploy' from the operator
# repo into a namespace check.sh does not know about.
PREREQS_CHECKED="${PREREQS_CHECKED:-false}"

# --- logging ----------------------------------------------------------------
if [[ -t 1 ]]; then
  _B="\033[1;34m"; _G="\033[1;32m"; _Y="\033[1;33m"; _R="\033[1;31m"; _X="\033[0m"
else _B=""; _G=""; _Y=""; _R=""; _X=""; fi
log()  { echo -e "${_B}==>${_X} $*"; }
ok()   { echo -e "${_G}✓${_X} $*"; }
warn() { echo -e "${_Y}!${_X} $*" >&2; }
err()  { echo -e "${_R}✗${_X} $*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || { err "missing command: $1"; exit 1; }; }

preflight() {
  require_cmd "${CLI}"
  "${CLI}" cluster-info >/dev/null 2>&1 || { err "cannot reach cluster via '${CLI}'"; exit 1; }
}

# True when the cluster serves the OpenShift route API. Cheaper and more
# reliable than reading the version: 'oc' talks to plain Kubernetes too, so the
# CLI in use says nothing about what is on the other end.
cluster_is_openshift() {
  "${CLI}" api-resources --api-group=route.openshift.io 2>/dev/null | grep -q "routes"
}

# Only an explicitly set PLATFORM can disagree with the cluster; a detected one
# came from the cluster in the first place. Warn rather than fail: overriding
# is legitimate (hand-installed Istio on OpenShift), getting it wrong by
# accident is not, and the two look identical from here.
require_platform_match() {
  "${PLATFORM_DETECTED}" && return 0
  if cluster_is_openshift && [[ "${PLATFORM}" != "openshift" ]]; then
    warn "PLATFORM='${PLATFORM}' but the cluster is OpenShift — expecting GatewayClass '${GATEWAY_CLASS}'."
    warn "Unset PLATFORM to let it be detected, unless you installed Istio yourself."
  fi
  if ! cluster_is_openshift && [[ "${PLATFORM}" == "openshift" ]]; then
    err "PLATFORM=openshift but the cluster has no route.openshift.io API."
    exit 1
  fi
}

has_crd() { "${CLI}" get crd "$1" >/dev/null 2>&1; }

# The CRDs every waf.sh verb needs. Checked up front because without them the
# CLI fails on the kind rather than the object: 'the server doesn't have a
# resource type "engine"'. --ignore-not-found does not cover that — it
# suppresses a missing object, not a missing kind — so 'waf.sh off' exits 1 on
# the very first step of a suite, and the message names neither the operator
# nor the installer that would fix it.
CORAZA_CRDS=(
  engines.waf.k8s.coraza.io
  rulesets.waf.k8s.coraza.io
  rulesources.waf.k8s.coraza.io
)

# Space-separated names of the Coraza CRDs that are absent; empty when all are
# present.
missing_operator_crds() {
  local crd out=""
  for crd in "${CORAZA_CRDS[@]}"; do
    has_crd "${crd}" || out+="${crd} "
  done
  printf '%s' "${out% }"
}

require_operator_crds() {
  local missing; missing="$(missing_operator_crds)"
  [[ -z "${missing}" ]] && return 0
  err "Coraza operator CRDs not found: ${missing}"
  err "The operator is not installed on this cluster, so there is no WAF to toggle."
  err "Install it:  scripts/prereqs/install-operator.sh  (or install-all.sh for everything)"
  err "Then verify: scripts/prereqs/check.sh"
  exit 1
}

# Gate an entry point on the full prerequisite check. The alternative — letting
# a run start and fail on whichever resource it touches first — costs a cluster
# setup and reports the symptom instead of the cause.
require_prereqs() {
  [[ "${PREREQS_CHECKED}" == "true" ]] && return 0
  # PT_ROOT, not a relative path: every caller happens to cd to the root first,
  # but the convention here is that a script works from anywhere.
  "${PT_ROOT}/scripts/prereqs/check.sh" || {
    err "Not starting a run: the cluster cannot produce a valid measurement yet."
    exit 1
  }
  export PREREQS_CHECKED=true
}

# Space-separated names of the WasmPlugins in the test namespace, which is the
# control-plane view of whether Envoy is running the WAF filter. The operator
# applies one per Engine via SSA into the gateway's own namespace, and that
# namespace belongs to this harness, so anything listed here is the WAF under
# test. No CRD means Istio cannot load a WASM filter at all, so report none.
# Deliberately no '|| true' on the query: a failed lookup must surface as a
# non-zero exit ("cannot tell"), never as an empty list ("nothing attached").
wasmplugin_names() {
  has_crd wasmplugins.extensions.istio.io || return 0
  "${CLI}" get wasmplugin -n "${NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'
}

# Block until no WasmPlugin is left in the namespace.
#   0 = gone, 1 = still there at the deadline, 2 = could not tell.
# Deleting the Engine only tells the operator to withdraw the filter: the
# WasmPlugin outlives the Engine by however long reconciliation takes, and
# Envoy keeps running the filter until istiod pushes the removal. A baseline
# measured inside that gap folds WAF cost into the number every later delta is
# subtracted from, which shrinks the reported overhead while looking valid.
wait_wasmplugin_absent() {
  local timeout="${1:-${WASM_WAIT_TIMEOUT}}" deadline names
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    names="$(wasmplugin_names)" || return 2
    [[ -z "${names// /}" ]] && return 0
    (( $(date +%s) >= deadline )) && return 1
    sleep 2
  done
}

# Exec a command in the load generator pod.
loadgen_exec() {
  "${CLI}" exec -n "${NAMESPACE}" "deploy/${LOADGEN_NAME}" -- "$@"
}
