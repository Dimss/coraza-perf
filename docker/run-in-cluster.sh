#!/usr/bin/env bash
#
# run-in-cluster.sh - drive the quick start inside the runner pod.
#
#   docker/run-in-cluster.sh prereqs            # install-all.sh (cluster change)
#   docker/run-in-cluster.sh check              # prereqs/check.sh
#   docker/run-in-cluster.sh setup              # setup.sh
#   docker/run-in-cluster.sh matrix             # run-comprehensive-tests.sh, detached
#   docker/run-in-cluster.sh suite <args...>    # suite.sh, detached
#   docker/run-in-cluster.sh logs               # tail the detached run's log
#   docker/run-in-cluster.sh status             # is a run in flight?
#   docker/run-in-cluster.sh fetch [dir]        # copy results/ out of the pod
#   docker/run-in-cluster.sh shell              # interactive shell
#
# Long runs are detached on purpose. The matrix is 45-55 minutes and `oc exec`
# holds one streaming connection for its whole length — the same class of
# failure the harness already works around by running the measured load as a
# Job rather than an exec (README, "Why a Job"). Detaching with setsid and
# logging to the results PVC means a dropped laptop connection costs you the
# log tail, not the run.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CLI="${CLI:-oc}"
RUNNER_NS="${RUNNER_NS:-waf-perf-runner}"
RUNNER_NAME="${RUNNER_NAME:-waf-perf-runner}"
WORKDIR=/opt/waf-perf-test
# On the PVC, so it survives a pod restart alongside the results it describes.
LOGDIR="${WORKDIR}/results/_runner-logs"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

pod() {
  "${CLI}" get pod -n "${RUNNER_NS}" -l "app=${RUNNER_NAME}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

POD="$(pod)"
[[ -n "${POD}" ]] || { err "no running runner pod in '${RUNNER_NS}' — run docker/build-and-deploy.sh"; exit 1; }

in_pod()  { "${CLI}" exec -n "${RUNNER_NS}" "${POD}" -- bash -lc "$*"; }
in_pod_i(){ "${CLI}" exec -it -n "${RUNNER_NS}" "${POD}" -- bash -lc "$*"; }

# Launch detached. The command is written into the pod as a launcher script
# first rather than passed inline: inline quoting through exec -> bash -lc ->
# setsid -> bash -c mangles anything with spaces, and a mangled scenario path
# fails 40 minutes in. The launcher records its own PID, so the in-flight
# check below tests a real process rather than a stale file.
#
# Refuses to start a second run: two concurrent matrices on one cluster
# interleave their load, and both numbers are then wrong while still looking
# plausible.
detach() {
  local name="$1"; shift
  local cmd="$*"

  # stderr discarded: with no run in flight this exits 1 and oc prints
  # "command terminated with exit code 1", which reads as a failure of the
  # thing you just asked for rather than as the answer "no, nothing running".
  if in_pod "test -f ${LOGDIR}/${name}.pid && kill -0 \$(cat ${LOGDIR}/${name}.pid) 2>/dev/null" 2>/dev/null; then
    err "a '${name}' run is already in flight — docker/run-in-cluster.sh logs ${name}"
    exit 1
  fi

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "echo \$\$ > ${LOGDIR}/${name}.pid" \
    "cd ${WORKDIR}" \
    "echo \"[runner] started \$(date -u +%Y-%m-%dT%H:%M:%SZ) : ${cmd}\"" \
    "${cmd}" \
    'rc=$?' \
    "echo \"[runner] finished \$(date -u +%Y-%m-%dT%H:%M:%SZ) EXIT=\${rc}\"" \
    "rm -f ${LOGDIR}/${name}.pid" \
    'exit ${rc}' \
  | "${CLI}" exec -i -n "${RUNNER_NS}" "${POD}" -- bash -c \
      "mkdir -p ${LOGDIR} && cat > ${LOGDIR}/${name}.sh && chmod +x ${LOGDIR}/${name}.sh"

  in_pod "setsid ${LOGDIR}/${name}.sh > ${LOGDIR}/${name}.log 2>&1 < /dev/null & sleep 2"
  log "started '${name}' in ${POD}"
  log "log: ${LOGDIR}/${name}.log  —  follow it with: docker/run-in-cluster.sh logs ${name}"
}

cmd="${1:-help}"; shift || true

case "${cmd}" in
  check)   in_pod "cd ${WORKDIR} && scripts/prereqs/check.sh" ;;
  prereqs) in_pod "cd ${WORKDIR} && scripts/prereqs/install-all.sh" ;;
  setup)   in_pod "cd ${WORKDIR} && scripts/setup.sh" ;;

  matrix)
    detach matrix "./run-comprehensive-tests.sh"
    ;;

  suite)
    [[ $# -gt 0 ]] || { err "usage: run-in-cluster.sh suite <scenario-file> [rulesets...]"; exit 1; }
    detach suite "scripts/suite.sh $*"
    ;;

  logs)
    name="${1:-}"
    if [[ -z "${name}" ]]; then
      name="$(in_pod "ls -t ${LOGDIR}/*.log 2>/dev/null | head -1 | xargs -r basename" | tr -d '\r')"
      name="${name%.log}"
    fi
    [[ -n "${name}" ]] || { err "no run logs yet in ${LOGDIR}"; exit 1; }
    log "tailing ${LOGDIR}/${name}.log (Ctrl-C to stop; the run keeps going)"
    "${CLI}" exec -n "${RUNNER_NS}" "${POD}" -- tail -n 200 -f "${LOGDIR}/${name}.log"
    ;;

  status)
    in_pod "ls -l ${LOGDIR}/ 2>/dev/null || echo 'no runs yet'; echo; \
            pgrep -af 'run-comprehensive-tests|suite.sh|fortio' || echo 'nothing running'"
    ;;

  fetch)
    dest="${1:-./results}"
    mkdir -p "${dest}"
    log "copying ${POD}:${WORKDIR}/results -> ${dest}"
    "${CLI}" cp "${RUNNER_NS}/${POD}:${WORKDIR}/results" "${dest}"
    log "done: ${dest}"
    ;;

  shell) in_pod_i "cd ${WORKDIR} && exec bash" ;;

  *)
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
