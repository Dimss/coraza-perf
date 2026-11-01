#!/usr/bin/env bash
#
# suite.sh - Run the canonical baseline-vs-WAF comparison for one scenario:
#   1. WAF off      (B0 baseline)
#   2. WAF on, once per ruleset given as an argument
#      (default: minimal = WASM floor, medium = typical policy, crs = OWASP CRS)
#
# Report WAF cost as the delta between each run and the WAF-off baseline.
#
#   suite.sh <scenario-file> [rulesets...]
#   suite.sh scenarios/fixed-500qps.env minimal medium crs
#   LOAD_PROFILE=args-heavy suite.sh scenarios/fixed-500qps.env crs
#
# Env:
#   COLLECT=true          Also pull Prometheus metrics around each run.
#   SETTLE=25s            Wait after toggling the WAF for the WASM poll to apply.
#   WASM_WAIT_TIMEOUT=60  Seconds waf.sh waits for the WasmPlugin to be
#                         withdrawn before the baseline. The suite aborts
#                         rather than measure a baseline through a live filter.
#   A blocking load profile (EXPECT_STATUS=403) is validated automatically;
#   the WAF-off baseline run forces EXPECT_STATUS=200.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=../lib.sh
source ./lib.sh
preflight
# preflight only proves the API is reachable. The suite's first act is to take
# a baseline, which is the most expensive thing to discover is unusable: a
# missing operator surfaces as a CLI error on an unknown kind, and a CRD older
# than the operator surfaces a ruleset later as a Ready wait that times out.
# Both are a couple of seconds to check here.
require_prereqs

SCENARIO_FILE="${1:?usage: suite.sh <scenario-file> [rulesets...]}"; shift || true
# Default covers the full cost curve: WASM floor -> typical policy -> CRS.
# Omitting crs here understated the headline number, since CRS is the dominant
# latency driver and the point of the comparison.
RULESETS=("$@"); [[ ${#RULESETS[@]} -eq 0 ]] && RULESETS=(minimal medium crs)
SETTLE="${SETTLE:-25s}"
COLLECT="${COLLECT:-false}"

# The result group run.sh will write under. Computed up front because
# collect.sh needs it per run, not just the report at the end.
SCENARIO_NAME="$(basename "${SCENARIO_FILE}" .env)"
SCN="${SCENARIO_NAME}"
if [[ -n "${LOAD_PROFILE:-}" ]]; then
  SCN="${SCN}+$(basename "${LOAD_PROFILE}" .env)"
fi

# One directory for this invocation of the suite: baseline and every ruleset
# run of this session land together with their metrics and their report.
# Exported so run.sh and collect.sh write into it instead of each making their
# own. Set RUN_DIR in the environment to add runs to an existing directory.
export RUN_DIR="${RUN_DIR:-$(new_run_dir "${SCENARIO_NAME}")}"
mkdir -p "${RUN_DIR}"
log "Run directory: ${RUN_DIR}"

run_one() {
  local tag="$1"; local baseline="$2"
  local start end
  start="$(date -u +%s)"
  # On the WAF-off baseline every shape must pass, including blocking profiles
  # that declare EXPECT_STATUS=403 for the WAF-on runs. Overriding here beats
  # the old attack-* filename heuristic: it keys off actual WAF state, and the
  # profile already says what it expects when the WAF is on.
  if [[ "${baseline}" == "baseline" ]]; then
    # EXPECT_WASM=false is the second half of the baseline gate. waf.sh off
    # already refuses to return success while the filter is attached; this
    # re-checks immediately before the load starts, so a WasmPlugin that
    # reappeared during the settle window (an Engine recreated by hand, an
    # operator retry) stops the run instead of contaminating the baseline.
    EXPECT_STATUS=200 EXPECT_WASM=false ./scripts/run.sh "${SCENARIO_FILE}" "${tag}"
  else
    ./scripts/run.sh "${SCENARIO_FILE}" "${tag}"
  fi
  end="$(date -u +%s)"
  if [[ "${COLLECT}" == "true" ]]; then
    ./scripts/collect.sh "${start}" "${end}" "${tag}" "${SCN}" \
      || warn "metric collection failed for ${tag}"
  fi
}

# --- 1. baseline: WAF off ---------------------------------------------------
log "=== Baseline: WAF OFF ==="
# waf.sh off exits non-zero if the WasmPlugin is still attached, so set -e
# stops the suite here rather than letting it record a contaminated baseline.
./scripts/waf.sh off
# The WasmPlugin is already gone by this point; the wait is for Envoy to apply
# the removal istiod pushed.
log "Settling ${SETTLE} for Envoy to drop the filter"; sleep "${SETTLE%s}"
run_one "waf-off" "baseline"

# --- 2..N: WAF on per ruleset ----------------------------------------------
for rs in "${RULESETS[@]}"; do
  log "=== WAF ON: ${rs} ==="
  ./scripts/waf.sh on "${rs}"
  log "Settling ${SETTLE} for the WasmPlugin to apply to Envoy (and poll, if cache enabled)"; sleep "${SETTLE%s}"
  run_one "waf-${rs}" "wafon"
done

echo
# Two reports, deliberately. The one in RUN_DIR covers this session alone —
# the same-session baseline the methodology asks you to report against. The
# one in RESULTS_DIR medians this session together with every earlier run of
# the scenario, which is the number you report once you have three of them.
if command -v python3 >/dev/null 2>&1; then
  log "Generating HTML report for this run: '${SCENARIO_NAME}'"
  if python3 ./scripts/report.py --results "${RUN_DIR}" --scenario "${SCENARIO_NAME}"; then
    ok "This run:     ${RUN_DIR}/${SCENARIO_NAME}-report.html"
  else
    warn "report generation failed; raw results are still in ${RUN_DIR}"
  fi
  if python3 ./scripts/report.py --results "${RESULTS_DIR}" --scenario "${SCENARIO_NAME}" \
       >/dev/null 2>&1; then
    ok "All runs:     ${RESULTS_DIR}/${SCENARIO_NAME}-report.html (medians across repeats)"
  fi
else
  warn "python3 not found — skipping HTML report (raw results in ${RUN_DIR})"
fi

ok "Suite complete. Compare summaries:"
echo "  grep -H . ${RUN_DIR}/${SCN}__*.summary.txt"
warn "Report WAF cost as (waf-* p95/p99) minus (waf-off p95/p99), same scenario/session."
