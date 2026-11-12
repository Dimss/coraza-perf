# Runner image for the Coraza WAF performance harness.
#
# The harness itself is unchanged by this: it is still the same bash that the
# README's Quick start runs on a workstation. All this image does is move the
# *orchestration* side into the cluster, so a run no longer depends on a laptop
# staying awake, on a local kubeconfig, or on a link to the API server that
# survives 45 minutes.
#
# The measured traffic never ran on the workstation in the first place — it is
# a fortio Job inside the cluster — so running the orchestrator in-cluster does
# not change what is being measured. It removes a failure mode, not a variable.
#
# Credentials: none are baked in. The pod authenticates with its ServiceAccount
# token; oc/kubectl pick up the in-cluster config on their own when KUBECONFIG
# is unset.
FROM registry.access.redhat.com/ubi9/ubi:latest

# Pinned, not 'latest'. The harness shells out to helm for the operator chart,
# and install-operator.sh's handling of chart CRDs is written against helm 4's
# apply semantics. A floating helm is the same class of defect as the unpinned
# fortio image the README calls out.
ARG HELM_VERSION=v4.2.2
# 'stable' is the current 4.x client. oc is a control-plane tool here; it is
# not on the measured path, so tracking stable is fine.
ARG OC_CHANNEL=stable

# findutils/procps-ng/gettext are not incidental: the scripts use find for
# result discovery, envsubst to render gateway.yaml and engine.yaml, and the
# report generator needs python3. Installing them here rather than discovering
# them missing 40 minutes into a matrix.
RUN dnf -y install --setopt=install_weak_deps=False --nodocs \
        bash tar gzip findutils procps-ng gettext \
        python3 python3-pip ca-certificates jq \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Arch comes from uname, not from TARGETARCH: this image is built both by
# docker buildx (which sets TARGETARCH) and by an OpenShift BuildConfig
# (which does not). uname is right in both, and a wrong arch here is the same
# failure the operator chart's amd64-only image produces — a pod that never
# starts.
RUN set -eux; \
    case "$(uname -m)" in \
      aarch64) arch=arm64 ;; \
      x86_64)  arch=amd64 ;; \
      *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/oc.tar.gz \
      "https://mirror.openshift.com/pub/openshift-v4/${arch}/clients/ocp/${OC_CHANNEL}/openshift-client-linux-${arch}-rhel9.tar.gz"; \
    tar -xzf /tmp/oc.tar.gz -C /usr/local/bin oc; \
    ln -sf /usr/local/bin/oc /usr/local/bin/kubectl; \
    rm -f /tmp/oc.tar.gz; \
    curl -fsSL -o /tmp/helm.tgz \
      "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz"; \
    tar -xzf /tmp/helm.tgz -C /tmp; \
    mv "/tmp/linux-${arch}/helm" /usr/local/bin/helm; \
    rm -rf /tmp/helm.tgz "/tmp/linux-${arch}"; \
    oc version --client; helm version --short

WORKDIR /opt/waf-perf-test

# Dependencies before sources, so editing a script does not re-resolve pip.
COPY requirements.txt /opt/waf-perf-test/requirements.txt
RUN python3 -m pip install --no-cache-dir -r /opt/waf-perf-test/requirements.txt

COPY . /opt/waf-perf-test

# results/ is a mount point. Creating it here means the image still works
# without a PVC attached — the run just does not survive the pod.
RUN mkdir -p /opt/waf-perf-test/results /home/runner \
    && chmod -R g+rwX /opt/waf-perf-test /home/runner \
    && chgrp -R 0 /opt/waf-perf-test /home/runner

# helm and oc both want a writable HOME for their caches; without this they
# fall back to / and fail on a read-only or root-owned filesystem.
# PLATFORM is deliberately NOT set. lib.sh detects it from the cluster, and a
# baked-in value would be an override that outlives the cluster it was right
# for — the failure mode lib.sh's comment describes, where the wrong
# GatewayClass surfaces as a hang on the Gateway readiness wait.
ENV HOME=/home/runner \
    PYTHONUNBUFFERED=1

# Idle by default. The pod exists to be exec'd into — the quick start is driven
# step by step (prereqs, setup, matrix) and each step wants its own log. An
# entrypoint that ran the matrix on start would re-run it on every restart,
# which is exactly how an accidental second measurement gets into results/.
CMD ["sleep", "infinity"]
