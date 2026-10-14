# turbostat-7149007 — isolated-CPU monitoring for DPDK pods on OpenShift

A debug container image (UBI9 base) bundling `turbostat`, Intel `pcm`, `crictl`,
`msr-tools`, and a helper that works around the cgroup v2 *isolated partition*
problem so these tools can read metrics for the isolated CPUs of a low-latency
DPDK pod.

> Image: `quay.io/midu/turbostat-7149007:latest`

## The problem

On OCP 4.18+ / RHCOS with cgroup v2, CRI-O places a low-latency pod's CPUs in an
*isolated* cpuset partition (`cpuset.cpus.partition = isolated`). The kernel then
removes those CPUs from `cpuset.cpus.effective` of every parent cgroup, including
`/sys/fs/cgroup`. `turbostat`/`pcm` read that file at startup and report:

```
cpu1 not effective
...
turbostat: No valid cpus found: Success
```

## What's in the image

| Tool | Package | Source | Arch |
|------|---------|--------|------|
| `turbostat` | `kernel-tools` | CentOS Stream 9 BaseOS (RHEL 9 / RHCOS upstream) | x86_64 |
| `pcm` | `pcm` | CentOS Stream 9 AppStream | x86_64 |
| `rdmsr`/`wrmsr` | `msr-tools` | EPEL 9 | x86_64 |
| `crictl` | cri-tools `v1.31.1` | upstream (matches OCP 4.18 / k8s 1.31) | all |
| `mount`/`umount`, `jq`, `gawk`, `kmod`, … | UBI 9 / EPEL | Red Hat | all |

**Base is 100% Red Hat UBI 9.** `turbostat`/`pcm`/`msr-tools` are not published in
UBI repos, so they are pulled (GPG-verified) from CentOS Stream 9 — Red Hat's
public RHEL 9 / RHCOS upstream — and the extra repo definitions are removed from
the final image. `turbostat`/`pcm`/`msr-tools` are Intel/x86-only and are only
installed on the `amd64` image variant.

## Usage

### Option 1 — pod-scoped (isolated CPUs of one pod) — automated

```bash
oc debug node/<node-name> --image=quay.io/midu/turbostat-7149007:latest
# inside the debug pod:
chroot /host            # optional, if you need host crictl/socket context

# find the DPDK container id, then:
monitor-isolated-cpus -c <container-id>                 # turbostat, auto-detect CPUs
monitor-isolated-cpus -c <container-id> -t pcm          # use pcm
monitor-isolated-cpus -c <container-id> -- --interval 2 # extra turbostat args
monitor-isolated-cpus -p <pid>                          # if you already have the PID
```

The helper reproduces the article's Option 1: resolve PID → find the leaf
cgroup → `mount --bind` it over `/sys/fs/cgroup` → join the cgroup → run the tool
against the now-effective isolated CPUs → unmount on exit.

### Option 1 — manual

```bash
PID=$(crictl inspect <container-id> | jq -r '.info.pid')
TARGET_CGROUP=$(awk -F: '$1=="0"{print $3}' /proc/$PID/cgroup)
mount --bind /sys/fs/cgroup${TARGET_CGROUP} /sys/fs/cgroup
cat /sys/fs/cgroup/cpuset.cpus.effective     # should now show the isolated range
echo $$ > /sys/fs/cgroup/cgroup.procs
turbostat --cpu $(cat /sys/fs/cgroup/cpuset.cpus.effective) --interval 2
umount /sys/fs/cgroup
```

### Option 2 — node-wide (all CPUs)

Run the binary directly from the host root context (bypasses the container
cpuset mask by reading MSRs directly):

```bash
oc debug node/<node-name> --image=quay.io/midu/turbostat-7149007:latest
chroot /host
# binaries live in this image's overlay under /var/lib/containers/storage/overlay/
turbostat --interval 2
```

## Build locally & push

Auth is read from `/home/midu/config.json` (containers auth format).

```bash
./build-and-push.sh                          # all arches -> :latest
PLATFORMS=linux/amd64 ./build-and-push.sh    # single arch (fast)
PUSH=false ./build-and-push.sh               # build only
```

Requires `podman` and `qemu-user-static` (for non-native arches).

## CI

`.github/workflows/build.yml` builds the multi-arch manifest
(amd64/arm64/ppc64le/s390x) and pushes to Quay on push to `main` / tags.
Set repo secrets `QUAY_USERNAME` and `QUAY_PASSWORD`.

## Notes / safety

- This is a **debugging** image. Running `turbostat`/`pcm` in production is not
  endorsed by the source article.
- The `mount --bind` is confined to the debug pod's mount namespace and is undone
  on exit; it does **not** alter host or node cgroups.
- Do **not** flip `cpuset.cpus.partition` from `isolated` to `member` on
  production nodes — it breaks DPDK real-time isolation.
