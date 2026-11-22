#!/usr/bin/env bash
#
# collect.sh - Pull control-plane, data-plane and container resource metrics
# from Prometheus for a given time window and save them alongside the load
# results. Best-effort: requires a reachable Prometheus (see PROM_* vars in
# lib.sh). The resource queries come from the kubelet's cAdvisor endpoint, which
# on some clusters is a different Prometheus from the one holding coraza_*; the
# two sets are therefore queried in separate passes against PROM_* and
# PROM_CADVISOR_* respectively.
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

# --- container resource queries (cAdvisor) ----------------------------------
# A label selector for one workload's containers. An empty container name means
# every container in the pod; the two exclusions drop the pod-level pause cgroup
# and the per-pod rollup, which cAdvisor emits as extra series under the same
# pod label and would otherwise double every figure.
selector() {  # selector <namespace> <pod-regex> <container-or-empty>
  local sel="namespace=\"$1\",pod=~\"$2\""
  if [[ -n "$3" ]]; then
    printf '%s,container="%s"' "${sel}" "$3"
  else
    printf '%s,container!="",container!="POD"' "${sel}"
  fi
}

GW_SEL="$(selector "${NAMESPACE}" "${GW_POD_REGEX}" "${GW_CONTAINER}")"
BE_SEL="$(selector "${NAMESPACE}" "${BACKEND_POD_REGEX}" "${BACKEND_CONTAINER}")"
LG_SEL="$(selector "${NAMESPACE}" "${LOADGEN_POD_REGEX}" "${LOADGEN_CONTAINER}")"
OP_SEL="$(selector "${CORAZA_NAMESPACE}" "${OPERATOR_POD_REGEX}" "${OPERATOR_CONTAINER}")"

# CPU is summed across replicas (the workload's total cost, which is what scales
# with offered load) and memory is a max over pods (one proxy's footprint, which
# is what has to fit in a limit). Summing memory instead would report a number
# that grows with replica count and means nothing on its own.
#
# working_set, not container_memory_usage_bytes: usage includes reclaimable page
# cache, so it drifts upward across a session and reads as a WAF memory cost
# that is really just file cache. working_set is also what the kubelet evicts on.
#
# The throttle ratio is the share of CFS periods in which the cgroup was held
# off the CPU. Anything above zero on the gateway means the latency measured is
# partly the limit, not the WAF; on the load generator it means the offered rate
# was capped by the client, which is the usual reason ActualQPS falls short.
declare -a RESOURCE_QUERIES=(
  "gw_cpu_cores|sum(rate(container_cpu_usage_seconds_total{${GW_SEL}}[1m]))"
  "gw_mem_bytes|max(container_memory_working_set_bytes{${GW_SEL}})"
  "gw_cpu_throttle_ratio|max(rate(container_cpu_cfs_throttled_periods_total{${GW_SEL}}[1m]) / rate(container_cpu_cfs_periods_total{${GW_SEL}}[1m]))"
  "backend_cpu_cores|sum(rate(container_cpu_usage_seconds_total{${BE_SEL}}[1m]))"
  "backend_mem_bytes|max(container_memory_working_set_bytes{${BE_SEL}})"
  "loadgen_cpu_cores|sum(rate(container_cpu_usage_seconds_total{${LG_SEL}}[1m]))"
  "loadgen_cpu_throttle_ratio|max(rate(container_cpu_cfs_throttled_periods_total{${LG_SEL}}[1m]) / rate(container_cpu_cfs_periods_total{${LG_SEL}}[1m]))"
  "operator_cpu_cores|sum(rate(container_cpu_usage_seconds_total{${OP_SEL}}[1m]))"
  "operator_mem_bytes|max(container_memory_working_set_bytes{${OP_SEL}})"
)

# --- execution --------------------------------------------------------------
PF_PID=""
pf_stop() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" 2>/dev/null || true
    PF_PID=""
  fi
}
trap pf_stop EXIT

# One Prometheus at a time, always on the same local port. Sequential rather
# than two concurrent forwards so the local port can never collide when the two
# instances are the same one, which is the common case.
pf_start() {  # pf_start <namespace> <svc> <remote-port>
  log "Port-forwarding Prometheus svc/$2 ($1):$3 -> localhost:${PROM_PORT}"
  "${CLI}" port-forward -n "$1" "svc/$2" "${PROM_PORT}:$3" >/dev/null 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 20); do
    curl -sf "http://localhost:${PROM_PORT}/-/ready" >/dev/null 2>&1 && return 0
    sleep 1
  done
  warn "Prometheus svc/$2 ($1) did not become ready; its queries will be empty"
}

run_queries() {  # run_queries <entry>...
  local entry name expr resp status
  for entry in "$@"; do
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
}

log "Querying $(( ${#QUERIES[@]} + ${#RESOURCE_QUERIES[@]} )) expressions over [${START}, ${END}] step=${STEP}"
: > "${out}"

pf_start "${PROM_NAMESPACE}" "${PROM_SVC}" "${PROM_PORT}"
run_queries "${QUERIES[@]}"
pf_stop

pf_start "${PROM_CADVISOR_NAMESPACE}" "${PROM_CADVISOR_SVC}" "${PROM_CADVISOR_PORT}"
run_queries "${RESOURCE_QUERIES[@]}"
pf_stop

ok "Metrics written to ${out}"
warn "If the coraza_* queries returned empty, confirm the ServiceMonitor (:8443) and PodMonitor (:15090) are enabled and scraped."
warn "If the resource queries returned empty, the cAdvisor series are in another Prometheus — set PROM_CADVISOR_NAMESPACE/_SVC (on OpenShift, prometheus-k8s in openshift-monitoring)."
