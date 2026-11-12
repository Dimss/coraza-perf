#!/usr/bin/env bash
#
# build-and-deploy.sh - build the runner image and put it on the cluster.
#
#   docker/build-and-deploy.sh            # build in-cluster, deploy, wait
#   LOCAL_BUILD=true docker/build-and-deploy.sh   # also docker build locally first
#
# Two builders, one Dockerfile:
#
#   - A local `docker build` is a fast syntax and download check. It does not
#     put the image anywhere the cluster can reach it, because the CRC-style
#     registry route is self-signed and making the Docker daemon trust it means
#     editing daemon.json and restarting Docker. Off by default for that
#     reason; set LOCAL_BUILD=true when you want the check.
#   - An OpenShift binary BuildConfig is what actually produces the deployed
#     image. It builds natively on the cluster's own architecture and pushes
#     straight into the internal registry, so there is no registry login, no
#     TLS exception, and no arch mismatch — the failure the operator chart's
#     amd64-only image produces.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CLI="${CLI:-oc}"
RUNNER_NS="${RUNNER_NS:-waf-perf-runner}"
RUNNER_NAME="${RUNNER_NAME:-waf-perf-runner}"
LOCAL_BUILD="${LOCAL_BUILD:-false}"
# The in-cluster registry service, resolvable from the Deployment. Not the
# external route: the kubelet pulls this, not your workstation.
INTERNAL_REGISTRY="${INTERNAL_REGISTRY:-image-registry.openshift-image-registry.svc:5000}"
IMAGE="${IMAGE:-${INTERNAL_REGISTRY}/${RUNNER_NS}/${RUNNER_NAME}:latest}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

command -v "${CLI}" >/dev/null || { err "missing command: ${CLI}"; exit 1; }
"${CLI}" cluster-info >/dev/null 2>&1 || { err "cannot reach the cluster via '${CLI}'"; exit 1; }

if [[ "${LOCAL_BUILD}" == "true" ]]; then
  command -v docker >/dev/null || { err "LOCAL_BUILD=true but docker is not on PATH"; exit 1; }
  log "Local docker build (validation only — not pushed)"
  docker build -f docker/Dockerfile -t "${RUNNER_NAME}:local" .
  ok "local image ${RUNNER_NAME}:local builds"
fi

# runner.yaml carries the default in-cluster registry reference literally, so
# it is applied as-is in the normal case. Only an IMAGE override needs a
# rewrite, and then the manifest is still valid YAML either way — no
# placeholder that could survive into the cluster the way an un-substituted
# ${ENGINE_NAME} would in gateway.yaml.
DEFAULT_IMAGE="${INTERNAL_REGISTRY}/${RUNNER_NS}/${RUNNER_NAME}:latest"
RENDERED="${TMPDIR:-/tmp}/waf-perf-runner.rendered.yaml"
sed "s|${DEFAULT_IMAGE}|${IMAGE}|" docker/runner.yaml > "${RENDERED}"

# The namespace has to exist before the build; the Deployment cannot be
# applied until the image it names does. So: namespace now, everything else
# after the build.
"${CLI}" create namespace "${RUNNER_NS}" --dry-run=client -o yaml | "${CLI}" apply -f -

log "Binary BuildConfig '${RUNNER_NAME}' in '${RUNNER_NS}'"
if ! "${CLI}" get buildconfig "${RUNNER_NAME}" -n "${RUNNER_NS}" >/dev/null 2>&1; then
  "${CLI}" new-build --name "${RUNNER_NAME}" --binary \
    --strategy docker --to "${RUNNER_NAME}:latest" -n "${RUNNER_NS}"
else
  ok "BuildConfig already exists"
fi

# new-build assumes ./Dockerfile. Ours lives in docker/, so the build would
# otherwise fail on "no Dockerfile in the context". Patched every time rather
# than only on create, so an older BuildConfig picks it up too.
"${CLI}" patch buildconfig "${RUNNER_NAME}" -n "${RUNNER_NS}" --type=merge \
  -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"docker/Dockerfile"}}}}' >/dev/null

log "Uploading the repo and building on the cluster (pulls oc + helm, ~3-5 min)"
# --follow so a failed layer is visible here rather than in a build log nobody
# reads; --wait so a non-zero build exits this script.
"${CLI}" start-build "${RUNNER_NAME}" -n "${RUNNER_NS}" --from-dir=. --follow --wait

ok "image built: $("${CLI}" get istag "${RUNNER_NAME}:latest" -n "${RUNNER_NS}" \
      -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || echo "${IMAGE}")"

log "Deploying the runner (ServiceAccount, RBAC, results PVC, Deployment)"
"${CLI}" apply -f "${RENDERED}"
# Force a pull of the tag we just rebuilt; the tag is unchanged, so without
# this a pre-existing pod keeps the old layers.
"${CLI}" rollout restart "deployment/${RUNNER_NAME}" -n "${RUNNER_NS}" >/dev/null 2>&1 || true
"${CLI}" rollout status "deployment/${RUNNER_NAME}" -n "${RUNNER_NS}" --timeout=300s

echo
ok "runner is up"
echo
echo "  Drive the quick start from inside it:"
echo "    ${CLI} exec -n ${RUNNER_NS} deploy/${RUNNER_NAME} -- scripts/prereqs/check.sh"
echo "    ${CLI} exec -n ${RUNNER_NS} deploy/${RUNNER_NAME} -- scripts/prereqs/install-all.sh"
echo "    ${CLI} exec -n ${RUNNER_NS} deploy/${RUNNER_NAME} -- scripts/setup.sh"
echo "    docker/run-in-cluster.sh matrix        # the 12-cell matrix, detached"
echo
