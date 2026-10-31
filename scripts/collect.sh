#!/usr/bin/env bash
#
# collect.sh - Pull control-plane and data-plane metrics from Prometheus for a
# given time window and save them alongside the load results. Best-effort:
# requires a reachable Prometheus (see PROM_* vars in lib.sh).
#
#   collect.sh <start_epoch> <end_epoch> [TAG] [SCENARIO]
#
# SCENARIO is the result group run.sh wrote under — "<scenario>" or
# "<scenario>+<load-profile>". It goes in the filename because report.py has no
# other way to tell which scenario a metrics window belongs to; without it the
# file is written anyway but no report will read it.
#
# Tip: run.sh prints window_utc; or wrap a run with:
#   START=$(date -u +%s); scripts/run.sh ...; END=$(date -u +%s)
#   scripts/collect.sh "$START" "$END" mytag fixed-500qps+args-heavy
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=../lib.sh
source ./lib.sh
require_cmd curl
preflight

START="${1:?usage: collect.sh <start_epoch> <end_epoch> [TAG] [SCENARIO]}"
END="${2:?usage: collect.sh <start_epoch> <end_epoch> [TAG] [SCENARIO]}"
TAG="${3:-untagged}"
SCENARIO="${4:-}"
STEP="${STEP:-15s}"

# Into the run's own directory when there is one, so a window sits beside the
# load it describes. RESULTS_DIR otherwise; the reporter reads both.
RUN_DIR="${RUN_DIR:-${RESULTS_DIR}}"
mkdir -p "${RUN_DIR}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -n "${SCENARIO}" ]]; then
  out="${RUN_DIR}/metrics__${SCENARIO}__${TAG}__${stamp}.jsonl"
else
  # Kept for a hand-run collection, but report.py skips these: a metrics window
  # that cannot be tied to a scenario used to be folded into whichever scenario
  # was being reported, pulling another run's server-side numbers into it.
  out="${RUN_DIR}/metrics__${TAG}__${stamp}.jsonl"
  warn "no SCENARIO given — report.py cannot attribute this file and will skip it"
fi

# Curated PromQL: data-plane (WAF) + control-plane (cache + reconcile).
declare -a QUERIES=(
  'waf_rps_by_outcome|sum by (outcome) (rate(coraza_waf_requests_total[1m]))'
  'waf_active_rule_count|max(coraza_waf_plugin_rule_count)'
  'waf_anomaly_p95|histogram_quantile(0.95, sum by (le) (rate(coraza_waf_request_anomaly_score_bucket[1m])))'
  'waf_plugin_loads|sum by (status) (coraza_waf_plugin_loads_total)'
  'cache_req_rate|sum by (handler,code) (rate(coraza_cache_server_requests_total[1m]))'
  'cache_latency_p99|histogram_quantile(0.99, sum by (le,handler) (rate(coraza_cache_server_request_duration_seconds_bucket[1m])))'
  'cache_inflight|max by (handler) (coraza_cache_server_in_flight_requests)'
  'cache_size_bytes|max(coraza_cache_size_bytes)'
  'reconcile_rate|sum by (controller,result) (rate(controller_runtime_reconcile_total[1m]))'
  'workqueue_depth|max by (name) (workqueue_depth)'
)

log "Port-forwarding Prometheus svc/${PROM_SVC} (${PROM_NAMESPACE}) -> localhost:${PROM_PORT}"
"${CLI}" port-forward -n "${PROM_NAMESPACE}" "svc/${PROM_SVC}" "${PROM_PORT}:${PROM_PORT}" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 20); do
  curl -sf "http://localhost:${PROM_PORT}/-/ready" >/dev/null 2>&1 && break
  sleep 1
done

log "Querying ${#QUERIES[@]} expressions over [${START}, ${END}] step=${STEP}"
: > "${out}"
for entry in "${QUERIES[@]}"; do
  name="${entry%%|*}"; expr="${entry#*|}"
  resp="$(curl -sG "http://localhost:${PROM_PORT}/api/v1/query_range" \
    --data-urlencode "query=${expr}" \
    --data-urlencode "start=${START}" \
    --data-urlencode "end=${END}" \
    --data-urlencode "step=${STEP}" 2>/dev/null || echo '{}')"
  printf '{"metric":"%s","query":%s,"result":%s}\n' \
    "${name}" "$(printf '%s' "${expr}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" \
    "${resp}" >> "${out}"
  status="$(printf '%s' "${resp}" | python3 -c 'import json,sys;
try: print(json.load(sys.stdin).get("status","?"))
except Exception: print("parse-error")' 2>/dev/null)"
  echo "  ${name}: ${status}"
done

ok "Metrics written to ${out}"
warn "If queries returned empty, confirm the ServiceMonitor (:8443) and PodMonitor (:15090) are enabled and scraped."
