#!/usr/bin/env bash
#
# waf.sh - Toggle the WAF on/off for baseline-vs-WAF comparison.
#
#   waf.sh on <minimal|medium|/path/to/ruleset.yaml>   # apply ruleset + engine
#   waf.sh off                                          # remove engine (WAF off)
#   waf.sh status                                       # show WAF resource state
#
# Removing the Engine (off) is the B0 baseline: traffic flows through the same
# Gateway/Envoy path with no WASM filter attached.
#
# Env knobs:
#   FAILURE_POLICY=fail|allow        Engine failure policy (default: fail).
#   POLL_CACHE=true                  Enable cache polling (ruleSetCacheServer);
#                                    default is static-embedded rules.
#   POLL_INTERVAL_SECONDS=15         Poll cadence when POLL_CACHE=true.
#   WASM_WAIT_TIMEOUT=60             Seconds 'off' waits for the WasmPlugin to
#                                    be withdrawn; it exits non-zero if it is
#                                    still attached, so no caller measures a
#                                    baseline through a live WAF filter.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=../lib.sh
source ./lib.sh
preflight

FAILURE_POLICY="${FAILURE_POLICY:-fail}"
case "${FAILURE_POLICY}" in
  fail|allow) ;;
  *) err "invalid FAILURE_POLICY='${FAILURE_POLICY}' (must be 'fail' or 'allow')"; exit 1;;
esac

# POLL_CACHE=true injects ruleSetCacheServer (cache-poll model); default is
# static-embedded rules. POLL_INTERVAL_SECONDS tunes the poll cadence.
POLL_CACHE="${POLL_CACHE:-false}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-15}"
if [[ "${POLL_CACHE}" == "true" ]]; then
  RULESET_CACHE_SERVER_BLOCK=$'  ruleSetCacheServer:\n    pollIntervalSeconds: '"${POLL_INTERVAL_SECONDS}"
else
  RULESET_CACHE_SERVER_BLOCK=""
fi

resolve_ruleset() {
  local sel="$1"
  # a bare name resolves to rulesets/<name>.yaml; anything else is a path
  if [[ -f "${RULESETS_DIR}/${sel}.yaml" ]]; then
    echo "${RULESETS_DIR}/${sel}.yaml"
  elif [[ -f "${sel}" ]]; then
    echo "${sel}"
  else
    err "unknown ruleset '${sel}' (no ${RULESETS_DIR}/${sel}.yaml and not a file)"
    exit 1
  fi
}

cmd="${1:-}"; shift || true
case "${cmd}" in
  on)
    require_operator_crds
    ruleset_file="$(resolve_ruleset "${1:-minimal}")"
    log "Applying ruleset from $(basename "${ruleset_file}")"
    "${CLI}" apply -n "${NAMESPACE}" -f "${ruleset_file}"

    log "Waiting for RuleSet '${RULESET_NAME}' to be Ready"
    "${CLI}" wait -n "${NAMESPACE}" "ruleset/${RULESET_NAME}" --for=condition=Ready --timeout="${WAIT_TIMEOUT}"

    log "Applying Engine '${ENGINE_NAME}' (failurePolicy=${FAILURE_POLICY}, cache-poll=${POLL_CACHE})"
    ENGINE_NAME="${ENGINE_NAME}" RULESET_NAME="${RULESET_NAME}" GATEWAY_NAME="${GATEWAY_NAME}" \
      FAILURE_POLICY="${FAILURE_POLICY}" RULESET_CACHE_SERVER_BLOCK="${RULESET_CACHE_SERVER_BLOCK}" \
      envsubst '${ENGINE_NAME} ${RULESET_NAME} ${GATEWAY_NAME} ${FAILURE_POLICY} ${RULESET_CACHE_SERVER_BLOCK}' \
      < "${MANIFESTS_DIR}/engine.yaml" | "${CLI}" apply -n "${NAMESPACE}" -f -

    log "Waiting for Engine '${ENGINE_NAME}' to be Ready"
    "${CLI}" wait -n "${NAMESPACE}" "engine/${ENGINE_NAME}" --for=condition=Ready --timeout="${WAIT_TIMEOUT}"

    warn "Allow Istio to apply the WasmPlugin to the Gateway Envoy (plus one poll"
    warn "interval ~15s if the cache is enabled) before measuring; run.sh validity-checks."
    ok "WAF enabled."
    ;;
  off)
    # Checked even though 'off' is the state a missing operator leaves you in.
    # Returning success here would be a lie with consequences: the suite would
    # record a WAF-off baseline, then fail on the first 'waf.sh on' with
    # nothing to compare it against, having spent the scenario duration on it.
    require_operator_crds
    log "Removing Engine '${ENGINE_NAME}' (WAF off / baseline)"
    "${CLI}" delete -n "${NAMESPACE}" engine "${ENGINE_NAME}" --ignore-not-found
    # The delete returns when the API server accepts it, not when the filter is
    # gone. This used to print an unconditional reminder to wait; waiting for
    # the WasmPlugin to actually disappear is both quieter when it works and a
    # real gate when it doesn't, because the failure it guards against — a
    # baseline measured with the filter still attached — produces a plausible
    # number rather than an error.
    log "Waiting up to ${WASM_WAIT_TIMEOUT}s for the WasmPlugin to be withdrawn"
    rc=0; wait_wasmplugin_absent "${WASM_WAIT_TIMEOUT}" || rc=$?
    case "${rc}" in
      0)
        ok "WasmPlugin withdrawn from namespace '${NAMESPACE}'."
        ok "WAF disabled."
        ;;
      2)
        err "Cannot list WasmPlugins in '${NAMESPACE}' — the WAF state is unknown."
        err "Refusing to report the WAF off: a baseline measured now may include WAF cost."
        exit 1
        ;;
      *)
        still="$(wasmplugin_names || true)"
        err "WasmPlugin still attached after ${WASM_WAIT_TIMEOUT}s: ${still%" "}"
        err "Envoy is likely still running the WAF filter, so a baseline measured now would"
        err "include its cost and understate every delta computed against it."
        err "Check the operator: ${CLI} get engine,wasmplugin -n ${NAMESPACE}"
        exit 1
        ;;
    esac
    ;;
  status)
    # Diagnostic, so it reports rather than exits — but it must not report
    # silence as "nothing configured". Both gets swallow their stderr, so with
    # no CRDs this printed two blank lines, which reads exactly like a healthy
    # WAF-off cluster.
    missing="$(missing_operator_crds)"
    if [[ -n "${missing}" ]]; then
      warn "Coraza operator CRDs not found: ${missing}"
      warn "Engine/RuleSet state is unknown, not empty — scripts/prereqs/install-operator.sh"
    else
      "${CLI}" get -n "${NAMESPACE}" engine,ruleset,rulesource 2>/dev/null || true
    fi
    "${CLI}" get -n "${NAMESPACE}" wasmplugin 2>/dev/null || true
    ;;
  *)
    echo "usage: waf.sh {on <ruleset>|off|status}" >&2; exit 1;;
esac
