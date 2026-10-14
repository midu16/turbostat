#!/usr/bin/env bash
# build-and-push.sh — build the multi-arch OCI image locally with podman and
# push it as a manifest list to quay.io/midu/turbostat-7149007:latest.
#
# Auth comes from /home/midu/config.json (containers auth / `podman login` format).
#
# Requirements:
#   - podman
#   - qemu-user-static (for building non-native arches)
#       Fedora:  sudo dnf install qemu-user-static
#       or:      podman run --rm --privileged \
#                    registry.access.redhat.com/ubi9/ubi \
#                    /bin/true   # (native only)
#
# Usage:
#   ./build-and-push.sh                 # build all arches and push :latest
#   PLATFORMS=linux/amd64 ./build-and-push.sh   # single arch (fast, native)
#   PUSH=false ./build-and-push.sh      # build only, do not push
set -euo pipefail

IMAGE="${IMAGE:-quay.io/midu/turbostat-7149007}"
TAG="${TAG:-latest}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64,linux/ppc64le,linux/s390x}"
AUTHFILE="${AUTHFILE:-/home/midu/config.json}"
PUSH="${PUSH:-true}"
MANIFEST="${IMAGE}:${TAG}"

cd "$(dirname "$0")"

echo "==> image      : ${MANIFEST}"
echo "==> platforms  : ${PLATFORMS}"
echo "==> auth file  : ${AUTHFILE}"

# Fresh manifest each run: drop any stale manifest list AND any plain image that
# happens to share the name (otherwise `build --manifest` errors with
# "image is not a manifest list").
podman manifest rm "${MANIFEST}" 2>/dev/null || true
podman rmi -f "${MANIFEST}" 2>/dev/null || true

echo "==> building..."
podman build \
    --platform "${PLATFORMS}" \
    --manifest "${MANIFEST}" \
    --file Containerfile \
    .

if [[ "${PUSH}" == "true" ]]; then
    [[ -f "${AUTHFILE}" ]] || { echo "error: auth file ${AUTHFILE} not found" >&2; exit 1; }
    echo "==> pushing manifest to ${MANIFEST}"
    podman manifest push --all \
        --authfile "${AUTHFILE}" \
        "${MANIFEST}" \
        "docker://${MANIFEST}"
    echo "==> done. Pull with: podman pull ${MANIFEST}"
else
    echo "==> PUSH=false, skipping push. Local manifest: ${MANIFEST}"
fi
