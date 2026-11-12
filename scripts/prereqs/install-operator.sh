#!/usr/bin/env bash
#
# install-operator.sh - Install the Coraza Kubernetes Operator: the published
# Helm chart for the deployment, a downstream build for the image, and the CRDs
# that match that image rather than the ones the chart ships.
#
#   scripts/prereqs/install-operator.sh
#
# Env: CORAZA_CHART_VERSION (pin it for a reportable run), CORAZA_NAMESPACE,
#      CORAZA_RELEASE, CORAZA_CHART_REPO, CORAZA_IMAGE_REPO/TAG,
#      CORAZA_CRD_REF, CORAZA_CRD_DIR (defaults in lib.sh)
#
# The image is resolved rather than taken from the chart because the chart's
# ghcr.io release is linux/amd64 only, so on arm64 the pod never starts. That
# makes the CRD source a consequence, not a separate choice: the resolved tag
# is a commit in CORAZA_BUILD_REPO, and the CRDs at that commit are the ones
# the running manager expects.
#
# CORAZA_IMAGE_REPO / CORAZA_IMAGE_TAG run a build of your own and opt out of
# both. Set CORAZA_CRD_DIR with them, pointing at the config/crd/bases of the
# revision that image was built from: the chart's CRDs are pinned to the chart,
# a newer operator needs fields they do not define, and the mismatch surfaces
# three steps later as a RuleSet that never goes Ready.
# See 'Image and CRDs' in docs/prerequisites.md.
#
# This installs a release build. To test operator changes you have not shipped,
# use 'make deploy' in the operator repo instead and skip this script.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../../lib.sh
source ./lib.sh
preflight
require_platform_match
require_cmd helm
require_cmd curl

has_crd wasmplugins.extensions.istio.io || {
  err "Istio is not installed — the operator has nothing to write WasmPlugins to."
  err "Run scripts/prereqs/install-istio.sh first."
  exit 1
}

log "Adding chart repo ${CORAZA_CHART_REPO}"
helm repo add "${CORAZA_CHART_REPO_NAME}" "${CORAZA_CHART_REPO}" --force-update
helm repo update "${CORAZA_CHART_REPO_NAME}"

# An install interrupted partway (Ctrl-C, a pod that never schedules, a killed
# CI step) leaves the release wedged in pending-install, and every later
# attempt fails with "another operation is in progress" instead of recovering.
# Clear it here rather than making the caller work that out.
release_status="$(helm status "${CORAZA_RELEASE}" -n "${CORAZA_NAMESPACE}" \
  -o json 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["info"]["status"])
except Exception: pass' 2>/dev/null || true)"
if [[ "${release_status}" == pending-* ]]; then
  warn "previous attempt left release '${CORAZA_RELEASE}' in '${release_status}'; removing it first"
  helm uninstall "${CORAZA_RELEASE}" -n "${CORAZA_NAMESPACE}" >/dev/null 2>&1 || true
fi

# Image. The chart's default is published for linux/amd64 only, so on anything
# else it cannot start at all; resolve-operator-image.sh picks the newest
# downstream build that actually carries this cluster's architecture, which it
# reads off the nodes. An explicit CORAZA_IMAGE_REPO still wins — that is the
# route for a build of your own.
if [[ -z "${CORAZA_IMAGE_REPO}" ]]; then
  log "No CORAZA_IMAGE_REPO set — resolving a build for this cluster"
  # Captured first, then eval'd, so the resolver's exit status survives.
  # 'eval "$(resolver)"' discards it: the substitution's status is not eval's,
  # and eval of an empty string succeeds, so set -e never fires. A resolver
  # that failed — quay unreachable, no build carrying this architecture, a
  # garbage-collected tag — then left CORAZA_IMAGE_REPO empty and the install
  # silently fell back to the chart's amd64-only image, which is the one thing
  # this whole branch exists to avoid. On an arm64 cluster that surfaces ten
  # minutes later as a helm --wait timeout on a pod that could never start.
  resolver_out="$(./scripts/prereqs/resolve-operator-image.sh)" || {
    err "could not resolve an operator image for this cluster."
    err "Without one the chart's default is amd64-only and the manager may never start."
    err "Set CORAZA_IMAGE_REPO/CORAZA_IMAGE_TAG for a build of your own, with"
    err "CORAZA_CRD_DIR=<checkout>/config/crd/bases for the revision it was built from."
    exit 1
  }
  eval "${resolver_out}"
  # Belt and braces: a resolver that exits 0 having printed nothing usable
  # would otherwise reach helm with the same empty variable.
  [[ -n "${CORAZA_IMAGE_REPO}" ]] || {
    err "resolve-operator-image.sh succeeded but set no CORAZA_IMAGE_REPO."
    exit 1
  }
  # The resolved tag is a commit in CORAZA_BUILD_REPO, so the CRDs that match
  # this exact image are reachable. Do not infer that for an image the caller
  # chose: its tag means nothing in that repo.
  CORAZA_CRD_REF="${CORAZA_CRD_REF:-${CORAZA_IMAGE_TAG}}"
fi

# No --wait, deliberately. The chart's ClusterRole is pinned to the chart the
# same way its CRDs are, so when the image comes from a newer release line the
# manager watches resources the rules do not grant and cannot start at all.
# That is corrected below, after helm has created the ClusterRole — which it
# must, because templates/clusterrole.yaml is unconditional with hardcoded
# rules and the chart has no rbac.create value to switch it off, so there is no
# --skip-crds equivalent for RBAC. With --wait, helm would block the full
# timeout watching a pod that cannot come up until that correction lands. The
# Available wait happens afterwards instead, and is no weaker for it.
args=(upgrade --install "${CORAZA_RELEASE}" "${CORAZA_CHART}"
      --namespace "${CORAZA_NAMESPACE}" --create-namespace
      --timeout 10m)

[[ -n "${CORAZA_CHART_VERSION}" ]] && args+=(--version "${CORAZA_CHART_VERSION}")

[[ -n "${CORAZA_IMAGE_REPO}" ]] && args+=(--set "image.repository=${CORAZA_IMAGE_REPO}")
[[ -n "${CORAZA_IMAGE_TAG}"  ]] && args+=(--set "image.tag=${CORAZA_IMAGE_TAG}")

# When we install the CRDs ourselves, helm must not also try. Helm 4 applies
# chart CRDs server-side rather than skipping ones that already exist, so it
# collides with whoever applied them first and aborts the whole install:
#   conflict with "kubectl-client-side-apply": .spec.versions
# --skip-crds is the supported way to say "they are handled".
[[ -n "${CORAZA_CRD_REF}${CORAZA_CRD_DIR}" ]] && args+=(--skip-crds)

# The same collision, one object over, and the one place --skip-crds has no
# counterpart: the RBAC correction below takes .rules on the ClusterRole under
# field manager 'waf-perf-test'. That makes the FIRST install succeed and every
# re-run fail, because helm's server-side apply then finds a field it does not
# own and aborts the whole upgrade:
#   conflict with "waf-perf-test": .rules
# This script is documented as safe to re-run and install-all.sh calls it
# unconditionally, so a second run has to work. Letting helm force the field
# back costs nothing: the correction below immediately re-applies the image's
# rules over the chart's with --force-conflicts of its own, so the end state
# after a re-run is byte-identical to a first install. Deleting the ClusterRole
# first would also clear the conflict, but it revokes a running manager's
# permissions for as long as the upgrade takes.
#
# Conditional because helm 3 has no such flag and would fail on an unknown one.
if helm upgrade --help 2>/dev/null | grep -q -- '--force-conflicts'; then
  args+=(--force-conflicts)
fi

# The pairing, stated once where both halves are known. An image that is not
# the chart's means the chart's CRDs are not the matching ones either: the two
# ship together and only agree when both come from the same revision. The
# resolution above sets CORAZA_CRD_REF itself, so this fires only for an image
# you chose. Not fatal — a build close enough to the chart works, and only you
# know which revision yours came from. But it is the combination that produces
# a WAF installing cleanly, reporting Ready on nothing, and timing out in
# waf.sh much later.
if [[ -z "${CORAZA_CRD_REF}" && -z "${CORAZA_CRD_DIR}" ]]; then
  warn "running an operator image that is not the chart's, against the chart's CRDs."
  warn "Set CORAZA_CRD_DIR=<checkout>/config/crd/bases for the revision that image was"
  warn "built from, or the RuleSet may never go Ready."
  warn "See 'Image and CRDs' in docs/prerequisites.md."
fi

if cluster_is_openshift; then
  # openshift.enabled drops runAsUser/fsGroup so the SCC can assign its own UID.
  # The revision must match the control plane the ingress operator created, or
  # the WasmPlugin is written against a revision no gateway proxy watches.
  log "OpenShift: targeting Istio revision '${OCP_ISTIO_REVISION}'"
  args+=(--set openshift.enabled=true --set "istio.revision=${OCP_ISTIO_REVISION}")
fi

# The chart's ServiceMonitor needs the Prometheus Operator CRD; without it the
# install fails on an unknown kind. collect.sh is the only consumer, so make it
# conditional rather than a hard prerequisite.
if has_crd servicemonitors.monitoring.coreos.com; then
  args+=(--set metrics.serviceMonitor.enabled=true)
else
  warn "No ServiceMonitor CRD — installing without metrics.serviceMonitor"
fi

# CRDs, before the install rather than after it.
#
# Helm lays down a chart's crds/ on first install and NEVER touches them on
# upgrade, so leaving it to do that left new code running against old CRDs.
# That failed here as RuleSource status patches returning "not found", because
# the older CRD had no status subresource — an error that names the object,
# not the schema, and sends you looking in the wrong place.
#
# The chart's are stale in released versions too, not only across upgrades:
# 0.5.0 ships rulesources and ruledata without that subresource. So prefer, in
# order, a local checkout, then the commit the image was built from, then the
# chart's own as a last resort. Applying is idempotent.
#
# Before, not after, and paired with --skip-crds above: helm 4 applies chart
# CRDs server-side rather than skipping existing ones, so letting it go first
# means the manager comes up against the stale schema, and letting it go at
# all means a field-manager conflict that aborts the install.
if [[ -n "${CORAZA_CRD_DIR}" ]]; then
  [[ -d "${CORAZA_CRD_DIR}" ]] || { err "CORAZA_CRD_DIR='${CORAZA_CRD_DIR}' is not a directory"; exit 1; }
  compgen -G "${CORAZA_CRD_DIR}/*.yaml" >/dev/null \
    || { err "no *.yaml in CORAZA_CRD_DIR='${CORAZA_CRD_DIR}'"; exit 1; }
  log "Applying CRDs from CORAZA_CRD_DIR (overrides the chart's)"
  "${CLI}" apply --server-side --force-conflicts \
    --field-manager=waf-perf-test -f "${CORAZA_CRD_DIR}/" >/dev/null
elif [[ -n "${CORAZA_CRD_REF}" ]]; then
  log "Applying CRDs from ${CORAZA_BUILD_REPO}@${CORAZA_CRD_REF:0:12}"
  crd_dir="$(mktemp -d)"
  fetched=0
  for crd in engines ruledata rulesets rulesources; do
    if curl -fsSL -o "${crd_dir}/${crd}.yaml" \
         "https://raw.githubusercontent.com/${CORAZA_BUILD_REPO}/${CORAZA_CRD_REF}/${CORAZA_BUILD_CRD_PATH}/waf.k8s.coraza.io_${crd}.yaml"; then
      fetched=$((fetched + 1))
    else
      warn "no ${crd} CRD at that commit"
    fi
  done
  if (( fetched > 0 )); then
    # Server-side, under our own field manager: a CRD left behind by an
    # earlier client-side apply or by helm is then taken over rather than
    # fought with on the next run.
    "${CLI}" apply --server-side --force-conflicts \
      --field-manager=waf-perf-test -f "${crd_dir}/" >/dev/null
    ok "Applied ${fetched} CRD(s) matching the image"
  else
    warn "fetched none; falling back to whatever the chart installs"
  fi
  rm -rf "${crd_dir}"
elif [[ -d "${CORAZA_CHART}/crds" ]]; then
  log "Applying the chart's CRDs (helm skips these on upgrade)"
  "${CLI}" apply -f "${CORAZA_CHART}/crds/" >/dev/null
else
  chart_crds="$(mktemp -d)"
  if helm pull "${CORAZA_CHART}" ${CORAZA_CHART_VERSION:+--version "${CORAZA_CHART_VERSION}"} \
       --untar --untardir "${chart_crds}" >/dev/null 2>&1 \
     && compgen -G "${chart_crds}"/*/crds/*.yaml >/dev/null; then
    log "Applying the chart's CRDs (helm skips these on upgrade)"
    "${CLI}" apply -f "${chart_crds}"/*/crds/ >/dev/null
  else
    warn "could not fetch the chart's CRDs to reapply them; upgrades may leave them stale"
  fi
  rm -rf "${chart_crds}"
fi

log "Installing ${CORAZA_CHART} into '${CORAZA_NAMESPACE}'"
helm "${args[@]}"

# --- RBAC, paired with the image exactly as the CRDs are --------------------
#
# Same defect, same cause, different object. Chart 0.5.0 grants
# gateway.networking.k8s.io/gateways but not gatewayclasses, and nothing at all
# in telemetry.istio.io; the waf-0-7 builds watch both. controller-runtime
# treats a cache that cannot sync as fatal, so the manager pulls its image,
# wins leader election, runs until the sync deadline and exits — CrashLoopBackOff,
# with the two "is forbidden" lines scrolled past minutes earlier and the fatal
# line reading only "failed to wait for rulesource caches to sync". Nothing in
# that sequence names RBAC.
#
# Only in the CRD_REF path. That is where we know which commit the image came
# from, so it is the only case where the matching rules are reachable; with
# CORAZA_CRD_DIR the caller is running their own build and owns its RBAC.
if [[ -z "${CORAZA_CRD_DIR}" && -n "${CORAZA_CRD_REF}" ]]; then
  log "Pairing RBAC with the image from ${CORAZA_BUILD_REPO}@${CORAZA_CRD_REF:0:12}"
  csv_file="$(mktemp)"
  if ! curl -fsSL -o "${csv_file}" \
       "https://raw.githubusercontent.com/${CORAZA_BUILD_REPO}/${CORAZA_CRD_REF}/${CORAZA_BUILD_CRD_PATH}/${CORAZA_BUNDLE_CSV}"; then
    warn "no CSV at that commit — leaving the chart's RBAC in place."
    warn "If the manager crashloops on 'caches to sync', this is why; check.sh names it."
  else
    # The ClusterRole is found by label rather than by name: the chart builds
    # the name from a template, and the release name is a variable here.
    cr_name="$("${CLI}" get clusterrole \
      -l "app.kubernetes.io/name=coraza-kubernetes-operator" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "${cr_name}" ]]; then
      warn "no ClusterRole labelled app.kubernetes.io/name=coraza-kubernetes-operator;"
      warn "leaving RBAC as the chart installed it."
    else
      # PyYAML, not '${CLI} create --dry-run=client': that needs a RESTMapping
      # for ClusterServiceVersion, so it only parses on a cluster that happens
      # to have OLM installed. python3 is already required by this script.
      if rbac_yaml="$(python3 - "${csv_file}" "${cr_name}" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit(3)
csv_path, name = sys.argv[1], sys.argv[2]
with open(csv_path) as fh:
    csv = yaml.safe_load(fh)
perms = csv.get("spec", {}).get("install", {}).get("spec", {}).get("clusterPermissions", [])
rules = [r for p in perms for r in p.get("rules", [])]
if not rules:
    sys.exit(4)
print(yaml.safe_dump({
    "apiVersion": "rbac.authorization.k8s.io/v1",
    "kind": "ClusterRole",
    "metadata": {"name": name},
    "rules": rules,
}, default_flow_style=False))
PY
      )"; then
        # Server-side with --force-conflicts, same as the CRDs: helm owns these
        # fields, and the point is to take them over rather than collide.
        printf '%s' "${rbac_yaml}" | "${CLI}" apply --server-side --force-conflicts \
          --field-manager=waf-perf-test -f - >/dev/null
        ok "ClusterRole '${cr_name}' now carries the image's own rules"
        # The pod is already backing off by now; without this it waits out the
        # CrashLoopBackOff interval before retrying with the corrected rules.
        "${CLI}" rollout restart deploy -n "${CORAZA_NAMESPACE}" \
          -l "app.kubernetes.io/name=coraza-kubernetes-operator" >/dev/null 2>&1 || true
      else
        rc=$?
        case "${rc}" in
          3) warn "PyYAML not installed, so the CSV cannot be read: 'pip install -r requirements.txt'." ;;
          4) warn "the CSV at that commit declares no clusterPermissions." ;;
          *) warn "could not read clusterPermissions out of the CSV (exit ${rc})." ;;
        esac
        warn "Leaving the chart's RBAC in place; the manager may crashloop on 'caches to sync'."
      fi
    fi
  fi
  rm -f "${csv_file}"
fi

# Ours rather than helm's, for the reason given where --wait was dropped.
log "Waiting up to ${CORAZA_WAIT_TIMEOUT} for the operator to become Available"
if ! "${CLI}" wait --for=condition=Available deploy \
     -l "app.kubernetes.io/name=coraza-kubernetes-operator" \
     -n "${CORAZA_NAMESPACE}" --timeout="${CORAZA_WAIT_TIMEOUT}"; then
  err "the operator did not become Available."
  err "If its log shows 'is forbidden', the chart's RBAC is older than the image:"
  err "  ${CLI} logs -n ${CORAZA_NAMESPACE} deploy/${CORAZA_RELEASE} | grep forbidden"
  exit 1
fi

# No f-string: backslash escapes inside an f-string expression are a syntax
# error before Python 3.12, and this silently printed "unknown" because of it.
installed="$(helm list -n "${CORAZA_NAMESPACE}" -o json 2>/dev/null | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r.get("name") == sys.argv[1]:
        print("chart %s, app %s" % (r.get("chart"), r.get("app_version")))
        break
else:
    print("unknown")' "${CORAZA_RELEASE}" 2>/dev/null || echo unknown)"

ok "Coraza operator installed (${installed})."

# The chart version no longer describes what is running: the manager is
# whatever image was resolved, and the CRDs come from that image's commit.
#
# The image is reported as the digest the node resolved, not as the tag we
# asked for. The chart renders "{{ repository }}:{{ tag }}" and has no digest
# field, so a @sha256: reference cannot be passed through CORAZA_IMAGE_TAG at
# all — and a commit-SHA tag in a staging registry can be rebuilt or collected,
# after which the digest is the only thing still identifying this binary.
resolved="$("${CLI}" get pods -n "${CORAZA_NAMESPACE}" \
  -l app.kubernetes.io/name=coraza-kubernetes-operator \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null || true)"
log "  image: ${resolved:-${CORAZA_IMAGE_REPO:-chart default}:${CORAZA_IMAGE_TAG:-chart default}}"
if [[ -n "${CORAZA_CRD_DIR}" ]]; then
  log "  CRDs:  ${CORAZA_CRD_DIR}"
elif [[ -n "${CORAZA_CRD_REF}" ]]; then
  log "  CRDs:  ${CORAZA_BUILD_REPO}@${CORAZA_CRD_REF}"
else
  log "  CRDs:  from the chart"
fi
warn "Record all three in any report — together they are what the number describes."
log "Verify the whole stack: scripts/prereqs/check.sh"
