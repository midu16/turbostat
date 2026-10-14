# Containerfile — CPU/hardware monitoring tools for isolated DPDK CPUs on OCP
# =============================================================================
# Fixes: turbostat / pcm report "cpuN not effective" / "No valid cpus found"
# for isolated CPUs assigned to low-latency DPDK pods. Under cgroup v2, CRI-O
# puts those CPUs in an *isolated* cpuset partition, so the kernel removes them
# from cpuset.cpus.effective of every parent cgroup (including /sys/fs/cgroup).
# Tools that read /sys/fs/cgroup/cpuset.cpus.effective at startup then see no
# valid CPUs. See /usr/local/bin/monitor-isolated-cpus for the workaround.
#
# Base image: Red Hat UBI 9 (registry.access.redhat.com/ubi9/ubi) — the base
# is kept 100% UBI. turbostat/pcm/msr-tools are not published in UBI repos, so
# they are pulled from Red Hat's CentOS Stream 9 (the RHEL 9 / RHCOS upstream,
# GPG-verified) and EPEL 9. The repo definitions are removed after install so
# the resulting image carries only UBI + the installed RPMs.
#
# Launch via:  oc debug node/<node> --image=quay.io/midu/turbostat-7149007:latest
# =============================================================================
FROM registry.access.redhat.com/ubi9/ubi:latest

# Set automatically by `podman build`/buildx for each target platform.
ARG TARGETARCH
ARG CRICTL_VERSION=v1.31.1

# Per-arch crictl (upstream cri-tools) sha256 — matches OCP 4.18 / Kubernetes 1.31
ARG CRICTL_SHA256_amd64=0a03ba6b1e4c253d63627f8d210b2ea07675a8712587e697657b236d06d7d231
ARG CRICTL_SHA256_arm64=cd70f9b2f75c9619f40450d4b6e2c74aaab619917da517eff6787b442f8b0e56
ARG CRICTL_SHA256_ppc64le=8a9f39335601ae3a749d90287a3f0980de01366748b83c0b067c0bf05228ad7d
ARG CRICTL_SHA256_s390x=46cb92e011b2d12d55a0c8dfed4c91f3a4ea73cabbce94bb2fd7e16dcc15c45a

# --- Red Hat-maintained tooling ---------------------------------------------
# Common (all arches): util-linux (mount/umount/findmnt), kmod (modprobe msr),
#   pciutils, procps-ng, gawk/grep/jq/coreutils for the article's shell flow.
# x86_64 only: kernel-tools (turbostat), pcm, msr-tools — these read Intel MSRs
#   and have no meaningful aarch64/ppc64le/s390x build.
RUN set -eux; \
    rpm --import https://www.centos.org/keys/RPM-GPG-KEY-CentOS-Official; \
    printf '%s\n' \
      '[c9s-baseos]' \
      'name=CentOS Stream 9 - BaseOS' \
      'baseurl=https://mirror.stream.centos.org/9-stream/BaseOS/$basearch/os/' \
      'gpgcheck=1' \
      'gpgkey=https://www.centos.org/keys/RPM-GPG-KEY-CentOS-Official' \
      'enabled=1' \
      '[c9s-appstream]' \
      'name=CentOS Stream 9 - AppStream' \
      'baseurl=https://mirror.stream.centos.org/9-stream/AppStream/$basearch/os/' \
      'gpgcheck=1' \
      'gpgkey=https://www.centos.org/keys/RPM-GPG-KEY-CentOS-Official' \
      'enabled=1' \
      > /etc/yum.repos.d/centos-stream.repo; \
    dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm; \
    dnf -y install \
        util-linux kmod pciutils procps-ng gawk grep jq tar gzip which; \
    if [ "${TARGETARCH}" = "amd64" ]; then \
        dnf -y install kernel-tools pcm msr-tools; \
    else \
        echo "NOTE: turbostat/pcm/msr-tools skipped on ${TARGETARCH} (x86_64-only)"; \
    fi; \
    dnf -y clean all; \
    rm -f /etc/yum.repos.d/centos-stream.repo; \
    rm -rf /var/cache/dnf /var/cache/yum

# --- crictl (multi-arch, pinned & checksum-verified) ------------------------
RUN set -eux; \
    eval "sha=\${CRICTL_SHA256_${TARGETARCH}}"; \
    curl -sSL -o /tmp/crictl.tar.gz \
        "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    echo "${sha}  /tmp/crictl.tar.gz" | sha256sum -c -; \
    tar -C /usr/local/bin -xzf /tmp/crictl.tar.gz; \
    rm -f /tmp/crictl.tar.gz; \
    crictl --version

# --- Helper automating the article's Option 1 (pod-scoped monitoring) -------
COPY monitor-isolated-cpus.sh /usr/local/bin/monitor-isolated-cpus
RUN chmod +x /usr/local/bin/monitor-isolated-cpus

# Point crictl at the host CRI-O socket as exposed inside an `oc debug node` pod.
ENV CONTAINER_RUNTIME_ENDPOINT=unix:///host/var/run/crio/crio.sock

LABEL org.opencontainers.image.title="turbostat-7149007" \
      org.opencontainers.image.description="turbostat/pcm + cgroup workaround for isolated DPDK CPUs on OpenShift 4.18+ (UBI9 base)" \
      org.opencontainers.image.base.name="registry.access.redhat.com/ubi9/ubi" \
      org.opencontainers.image.source="https://quay.io/midu/turbostat-7149007" \
      io.k8s.display-name="Isolated-CPU monitoring tools" \
      io.openshift.tags="turbostat,pcm,dpdk,cpu,performance,debug" \
      maintainer="midu"

ENTRYPOINT ["/bin/bash"]
