#!/usr/bin/env bash
#
# install-istio.sh - Provide the Istio control plane and the GatewayClass the
# harness measures through.
#
# OpenShift: the cluster ingress operator owns this. Creating a GatewayClass
#   with controller 'openshift.io/gateway-controller/v1' makes it install OSSM
#   and an Istio control plane under the revision it chose (openshift-gateway).
#   Installing Istio by hand on OpenShift gives you a second control plane that
#   the managed gateway ignores.
# Kubernetes: upstream Istio via istioctl.
#
#   scripts/prereqs/install-istio.sh
#
# Env: ISTIO_VERSION, ISTIO_PROFILE, OCP_GATEWAY_CONTROLLER (defaults in lib.sh)
#
# The Sail Operator is a third route, used by the operator repo's own dev
# clusters. It is not reimplemented here — see hack/install-istio.sh in
# https://github.com/networking-incubator/coraza-kubernetes-operator
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../../lib.sh
source ./lib.sh
preflight
require_platform_match

# Wait for a CRD to appear. 'kubectl wait' cannot wait on a resource that does
# not exist yet, and on OpenShift this one arrives only after OLM has resolved
# and installed OSSM, which is minutes rather than seconds.
wait_for_crd() {
  local crd="$1" timeout="${2:-600}" waited=0
  while ! has_crd "${crd}"; do
    if (( waited >= timeout )); then
      err "timed out after ${timeout}s waiting for CRD ${crd}"
      return 1
    fi
    sleep 10; waited=$((waited + 10))
    (( waited % 60 == 0 )) && log "  still waiting for ${crd} (${waited}s)"
  done
}

install_openshift() {
  log "Creating GatewayClass '${GATEWAY_CLASS}' (controller ${OCP_GATEWAY_CONTROLLER})"
  # This single object is the whole trigger: the ingress operator reads it,
  # then installs the OSSM version pinned in its own deployment env
  # (GATEWAY_API_OPERATOR_VERSION / ISTIO_VERSION). The harness does not get to
  # choose those versions, so record them rather than set them.
  "${CLI}" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: ${GATEWAY_CLASS}
spec:
  controllerName: ${OCP_GATEWAY_CONTROLLER}
EOF

  log "Waiting for the ingress operator to install OSSM (several minutes)"
  wait_for_crd wasmplugins.extensions.istio.io 900

  log "Waiting for GatewayClass '${GATEWAY_CLASS}' to be accepted"
  "${CLI}" wait --for=condition=Accepted "gatewayclass/${GATEWAY_CLASS}" --timeout=600s

  # '|| true' is load-bearing, not defensive noise. This is a cosmetic version
  # readout, but grep exits 1 when it matches nothing, pipefail turns that into
  # the pipeline's status, and a standalone assignment takes the pipeline's
  # status as its own — so set -e kills the script here. The 2>/dev/null only
  # covers the 'get', and ${pinned:-unknown} below never gets the chance to do
  # its job. An ingress operator that does not publish these two variables,
  # under a different name, or in a namespace we cannot read, would therefore
  # abort install-istio.sh *after* Istio is fully installed and working — and
  # install-all.sh would stop there, leaving a cluster with a healthy Istio and
  # no operator, having printed nothing that points at the cause.
  local pinned
  pinned="$("${CLI}" get deploy ingress-operator -n openshift-ingress-operator \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null \
    | grep -E '^(GATEWAY_API_OPERATOR_VERSION|ISTIO_VERSION)=' | tr '\n' ' ' || true)"
  ok "Istio ready. Versions the cluster pinned: ${pinned:-unknown}"
  warn "Record those in any report: nothing in generate-report.py reads them."
}

install_kubernetes() {
  has_crd gateways.gateway.networking.k8s.io || {
    err "Gateway API CRDs missing. Run scripts/prereqs/install-gateway-api.sh first."
    exit 1
  }

  if command -v istioctl >/dev/null 2>&1; then
    local have
    have="$(istioctl version --remote=false 2>/dev/null | head -1)"
    log "Using the istioctl already on PATH (${have})"
    [[ "${have}" == *"${ISTIO_VERSION}"* ]] || \
      warn "that is not ISTIO_VERSION=${ISTIO_VERSION}; the installed control plane will match istioctl, not the variable"
  else
    log "Downloading istioctl ${ISTIO_VERSION}"
    curl -fsSL https://istio.io/downloadIstio | ISTIO_VERSION="${ISTIO_VERSION}" sh -
    export PATH="${PWD}/istio-${ISTIO_VERSION}/bin:${PATH}"
  fi

  log "Installing Istio (profile ${ISTIO_PROFILE})"
  istioctl install --set profile="${ISTIO_PROFILE}" -y

  log "Waiting for the '${GATEWAY_CLASS}' GatewayClass istiod creates"
  local waited=0
  until "${CLI}" get gatewayclass "${GATEWAY_CLASS}" >/dev/null 2>&1; do
    (( waited >= 180 )) && { err "istiod did not create GatewayClass '${GATEWAY_CLASS}'"; exit 1; }
    sleep 5; waited=$((waited + 5))
  done
  "${CLI}" wait --for=condition=Accepted "gatewayclass/${GATEWAY_CLASS}" --timeout=120s
  ok "Istio installed."
}

if cluster_is_openshift; then install_openshift; else install_kubernetes; fi

log "Next: scripts/prereqs/install-operator.sh"
