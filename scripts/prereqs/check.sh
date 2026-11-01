#!/usr/bin/env bash
#
# check.sh - Verify everything the harness assumes is already on the cluster.
#
# setup.sh does not check any of this: it applies the Gateway and then waits on
# a Programmed condition that, with no GatewayClass or no Istio, never arrives.
# That failure looks like a hang. This tells you which piece is missing in a
# couple of seconds instead.
#
#   scripts/prereqs/check.sh          # report, exit 1 if anything is missing
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../../lib.sh
source ./lib.sh
preflight

missing=0
# $1 label, $2 fix hint, then the predicate as the remaining arguments.
check() {
  local label="$1" fix="$2"; shift 2
  if "$@" >/dev/null 2>&1; then
    ok "${label}"
  else
    err "${label} — ${fix}"
    missing=$((missing + 1))
  fi
}

log "Platform: ${PLATFORM} ($("${PLATFORM_DETECTED}" && echo detected || echo "from PLATFORM"), CLI '${CLI}', gateway class '${GATEWAY_CLASS}')"
require_platform_match

check "Gateway API CRDs" \
  "scripts/prereqs/install-gateway-api.sh" \
  has_crd gateways.gateway.networking.k8s.io

check "GatewayClass '${GATEWAY_CLASS}' exists" \
  "scripts/prereqs/install-istio.sh" \
  "${CLI}" get gatewayclass "${GATEWAY_CLASS}"

# An unaccepted GatewayClass still accepts Gateways; they just never program.
check "GatewayClass '${GATEWAY_CLASS}' accepted by its controller" \
  "its controller has not accepted it — ${CLI} describe gatewayclass ${GATEWAY_CLASS}" \
  "${CLI}" wait --for=condition=Accepted "gatewayclass/${GATEWAY_CLASS}" --timeout=5s

# The module under test is delivered as a WasmPlugin. No CRD, no measurement.
check "Istio WasmPlugin CRD" \
  "Istio is not installed — scripts/prereqs/install-istio.sh" \
  has_crd wasmplugins.extensions.istio.io

for crd in engines rulesets rulesources; do
  check "Coraza CRD ${crd}.waf.k8s.coraza.io" \
    "operator not installed — scripts/prereqs/install-operator.sh" \
    has_crd "${crd}.waf.k8s.coraza.io"
done

# Present is not the same as current. The operator writes status to RuleSource
# and RuleData, and a CRD without that subresource rejects the patch as "not
# found" — which surfaces three steps later as a RuleSet stuck on
# AwaitingRuleSourceValidation and waf.sh timing out on the Ready wait. Cheap
# to assert here, expensive to diagnose there.
crd_has_status() {
  [[ "$("${CLI}" get crd "$1" -o jsonpath='{.spec.versions[*].subresources.status}' 2>/dev/null)" != "" ]]
}
for crd in rulesources ruledata; do
  check "CRD ${crd}.waf.k8s.coraza.io serves /status" \
    "CRD is older than the operator — re-run scripts/prereqs/install-operator.sh, or set CORAZA_CRD_DIR=<checkout>/config/crd/bases for a build of your own" \
    crd_has_status "${crd}.waf.k8s.coraza.io"
done

# Not written with check(), because the useful message depends on why it
# failed and check() fixes its hint before running the predicate.
#
# The common cause is RBAC older than the image, and it is near-invisible from
# the outside: the manager pulls, starts, wins leader election, then exits when
# its caches cannot sync, so 'get pods' shows CrashLoopBackOff and the fatal
# log line reads "failed to wait for rulesource caches to sync". The actual
# denials are "is forbidden" warnings minutes earlier in the same log. Chart
# 0.5.0 against a waf-0-7 image misses telemetry.istio.io/telemetries and
# gateway.networking.k8s.io/gatewayclasses this way. Name it here rather than
# leave it to be rediscovered.
operator_denied_rules() {
  local logs
  for prev in "" "--previous"; do
    # shellcheck disable=SC2086
    logs="$("${CLI}" logs -n "${CORAZA_NAMESPACE}" \
      -l app.kubernetes.io/name=coraza-kubernetes-operator \
      --tail=3000 --all-containers ${prev} 2>/dev/null || true)"
    [[ -n "${logs}" ]] || continue
    local found
    found="$(printf '%s' "${logs}" \
      | grep -oE 'cannot [a-z]+ resource \\?"[a-z]+\\?" in API group \\?"[^"\\]*\\?"' \
      | sed -E 's|.*resource \\?"([a-z]+)\\?".*API group \\?"([^"\\]*)\\?".*|\2/\1|' \
      | sort -u | tr '\n' ' ' || true)"
    [[ -n "${found}" ]] && { printf '%s' "${found% }"; return 0; }
  done
  return 0
}

if "${CLI}" wait --for=condition=Available deploy \
     -l app.kubernetes.io/name=coraza-kubernetes-operator \
     -n "${CORAZA_NAMESPACE}" --timeout=5s >/dev/null 2>&1; then
  ok "Coraza operator available in '${CORAZA_NAMESPACE}'"
else
  denied="$(operator_denied_rules)"
  if [[ -n "${denied}" ]]; then
    err "Coraza operator available in '${CORAZA_NAMESPACE}' — RBAC is older than the operator image."
    err "  the manager is denied: ${denied}"
    err "  its caches cannot sync, so it exits and the pod crashloops."
    err "  fix: re-run scripts/prereqs/install-operator.sh, which now takes the"
    err "       ClusterRole from the same commit as the image."
  else
    err "Coraza operator available in '${CORAZA_NAMESPACE}' — operator CRDs exist but no manager is running — ${CLI} get pods -n ${CORAZA_NAMESPACE}"
  fi
  missing=$((missing + 1))
fi

# Optional, and only a warning: collect.sh needs it, a latency run does not.
if "${CLI}" get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  ok "ServiceMonitor CRD (metrics collection available)"
else
  warn "No ServiceMonitor CRD — scripts/collect.sh will have nothing to scrape"
fi

echo
if (( missing > 0 )); then
  err "${missing} prerequisite(s) missing. Install them: scripts/prereqs/install-all.sh"
  # Not every failure above is fixed by a plain re-install — a CRD older than
  # the operator is reinstalled identically unless CORAZA_CRD_DIR says
  # otherwise. Each check prints its own fix; say so rather than let the
  # generic line send someone round the same loop.
  err "Where a check named a different fix, prefer that one."
  err "Details and the manual equivalents: docs/prerequisites.md"
  exit 1
fi
ok "All prerequisites present. Next: scripts/setup.sh"
