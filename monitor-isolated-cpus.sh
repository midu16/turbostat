#!/usr/bin/env bash
# monitor-isolated-cpus — run turbostat/pcm against the isolated CPUs of a
# low-latency DPDK pod on OpenShift, working around the cgroup v2 "isolated
# partition" problem described in the Red Hat solution for case 7149007.
#
# Background: CRI-O places a low-latency pod's CPUs in an isolated cpuset
# partition, so the kernel strips them from cpuset.cpus.effective of every
# parent cgroup. turbostat/pcm read /sys/fs/cgroup/cpuset.cpus.effective at
# startup and therefore see "No valid cpus found". This script bind-mounts the
# target container's leaf cgroup over /sys/fs/cgroup inside this (debug pod)
# mount namespace, joins it, then runs the tool — exactly the article's Option 1.
#
# Must run as root inside an `oc debug node/<node>` session (privileged).
#
# Usage:
#   monitor-isolated-cpus -c <container-id> [-t turbostat|pcm] [-- <extra tool args>]
#   monitor-isolated-cpus -p <pid>          [-t turbostat|pcm] [-- <extra tool args>]
#
# Examples:
#   monitor-isolated-cpus -c 1a2b3c4d                       # auto-detect cpus, turbostat
#   monitor-isolated-cpus -c 1a2b3c4d -t pcm                # use pcm instead
#   monitor-isolated-cpus -c 1a2b3c4d -- --interval 2       # pass args to turbostat
set -euo pipefail

TOOL="turbostat"
CID=""
PID=""
CGROOT="/sys/fs/cgroup"
EXTRA_ARGS=()

die() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --- parse args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--container) CID="${2:?}"; shift 2 ;;
        -p|--pid)       PID="${2:?}"; shift 2 ;;
        -t|--tool)      TOOL="${2:?}"; shift 2 ;;
        -h|--help)      usage 0 ;;
        --)             shift; EXTRA_ARGS=("$@"); break ;;
        *)              die "unknown argument: $1 (see --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "must run as root (inside 'oc debug node/<node>')"
command -v "$TOOL" >/dev/null 2>&1 || die "tool '$TOOL' not found in image (x86_64 only for turbostat/pcm)"

# --- resolve PID from container id if needed --------------------------------
if [[ -z "$PID" ]]; then
    [[ -n "$CID" ]] || die "provide -c <container-id> or -p <pid> (see --help)"
    command -v crictl >/dev/null 2>&1 || die "crictl not found; pass -p <pid> instead"
    echo "==> inspecting container $CID via crictl"
    PID="$(crictl inspect "$CID" | jq -r '.info.pid // .pid // empty')"
    [[ -n "$PID" && "$PID" != "null" ]] || die "could not determine PID for container $CID"
fi
[[ -d "/proc/$PID" ]] || die "no such process: PID $PID"
echo "==> target PID: $PID"

# --- locate the container's leaf cgroup (cgroup v2, line starting '0::') -----
TARGET_CGROUP="$(awk -F: '$1=="0"{print $3}' "/proc/$PID/cgroup")"
[[ -n "$TARGET_CGROUP" ]] || die "could not read cgroup v2 path for PID $PID (is the node cgroup v2?)"
echo "==> container leaf cgroup: $TARGET_CGROUP"
[[ -d "${CGROOT}${TARGET_CGROUP}" ]] || die "cgroup path ${CGROOT}${TARGET_CGROUP} not found"

# --- bind-mount leaf cgroup over /sys/fs/cgroup (this mount ns only) ---------
cleanup() {
    echo "==> unmounting shadowed cgroup"
    umount "$CGROOT" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> bind-mounting ${CGROOT}${TARGET_CGROUP} -> ${CGROOT}"
mount --bind "${CGROOT}${TARGET_CGROUP}" "$CGROOT"

EFF="$(cat "${CGROOT}/cpuset.cpus.effective" 2>/dev/null || true)"
[[ -n "$EFF" ]] || die "cpuset.cpus.effective is empty after bind-mount"
echo "==> isolated CPUs now effective: $EFF"

# --- join the cgroup so the tool inherits the isolated cpuset ----------------
echo $$ > "${CGROOT}/cgroup.procs"

# --- run the monitoring tool ------------------------------------------------
echo "==> running: $TOOL --cpu $EFF ${EXTRA_ARGS[*]:-}"
echo "-------------------------------------------------------------------------"
if [[ "$TOOL" == "turbostat" ]]; then
    exec turbostat --cpu "$EFF" "${EXTRA_ARGS[@]:---interval 2}"
else
    exec "$TOOL" --cpu "$EFF" "${EXTRA_ARGS[@]}"
fi
