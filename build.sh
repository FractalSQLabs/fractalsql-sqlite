#!/bin/bash
#
# fractalsql-sqlite Docker build (v2: pure-C multi-TU, vendored core
# drop).
#
# Drives docker/Dockerfile to produce fractalsql.so for one (arch, profile)
# combination per invocation:
#   dist/amd64/fractalsql.so              # modern (glibc 2.34, sovereign)
#   dist/amd64/fractalsql-legacy.so       # legacy (glibc 2.28, minimal)
#
# Usage:
#   ./build.sh [amd64|arm64] [--profile=modern|legacy|musl]
#   PROFILE=legacy ./build.sh amd64
#
# Profiles:
#   modern (default)  base rockylinux:9, glibc 2.34, GCC 11, no suffix,
#                     community-sovereign-c (full 2.x surface)
#   legacy            base manylinux_2_28 (x86_64/aarch64 by arch),
#                     glibc 2.28, GCC 8,
#                     -legacy suffix; community-minimal-c (degraded
#                     surface — sovereign-only names raise clean SQL
#                     errors instead of linking)
#   musl              base alpine:3.20, -musl suffix,
#                     community-sovereign-c-musl
#
# The vendored drops are per-arch (include/linux-x86_64/ +
# include/linux-aarch64/), so both buildx platforms build from the
# same repo context.
#
# Refresh the vendored archive from the foundry:
#   cd ../fractalsql-core && make validated-drop-native
#   ./scripts/deploy.sh --git fractalsql-sqlite

set -euo pipefail

ARCH="${1:-amd64}"
case "${ARCH}" in
    amd64) ;;
    arm64) ;;  # V1 Phase 5b: arm64 enabled. Native build on ubuntu-24.04-arm runners.
    *) echo "unknown arch '${ARCH}' — expected amd64 or arm64" >&2; exit 2 ;;
esac

PROFILE="${PROFILE:-modern}"
for arg in "$@"; do
    case "$arg" in
        --profile=*) PROFILE="${arg#--profile=}" ;;
    esac
done
case "${PROFILE}" in
    modern|legacy|musl) ;;
    *) echo "unknown profile '${PROFILE}' — expected modern, legacy, or musl" >&2; exit 2 ;;
esac

if [[ "${PROFILE}" = "legacy" ]]; then
    # manylinux_2_28 images are per-arch: the x86_64 image cannot run
    # on an arm64 host (buildx would happily schedule it there, and
    # every RUN dies with "exec /bin/sh: exec format error"). Pick the
    # image matching the target platform.
    case "${ARCH}" in
        amd64) BASE_IMAGE="quay.io/pypa/manylinux_2_28_x86_64" ;;
        arm64) BASE_IMAGE="quay.io/pypa/manylinux_2_28_aarch64" ;;
    esac
    OUTPUT_SUFFIX="-legacy"
    SIZE_CEILING_BYTES="4194304"   # 4 MB
    CORE_VARIANT="community-minimal-c"
elif [[ "${PROFILE}" = "musl" ]]; then
    BASE_IMAGE="alpine:3.20"
    OUTPUT_SUFFIX="-musl"
    SIZE_CEILING_BYTES="4194304"   # 4 MB
    CORE_VARIANT="community-sovereign-c-musl"
else
    BASE_IMAGE="rockylinux:9"
    OUTPUT_SUFFIX=""
    SIZE_CEILING_BYTES="4194304"   # 4 MB
    CORE_VARIANT="community-sovereign-c"
fi

DIST_DIR="${DIST_DIR:-./dist}"
DOCKERFILE="${DOCKERFILE:-docker/Dockerfile}"
PLATFORM="linux/${ARCH}"
OUT_DIR="${DIST_DIR}/${ARCH}"

mkdir -p "${OUT_DIR}"

echo "------------------------------------------"
echo "Building fractalsql-sqlite"
echo "  arch:     ${PLATFORM}"
echo "  profile:  ${PROFILE}"
echo "  base:     ${BASE_IMAGE}"
echo "  core:     ${CORE_VARIANT}"
echo "  output:   ${OUT_DIR}/fractalsql${OUTPUT_SUFFIX}.so"
echo "------------------------------------------"

DOCKER_BUILDKIT=1 docker buildx build \
    --platform "${PLATFORM}" \
    --target export \
    --output "type=local,dest=${OUT_DIR}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "OUTPUT_SUFFIX=${OUTPUT_SUFFIX}" \
    --build-arg "SIZE_CEILING_BYTES=${SIZE_CEILING_BYTES}" \
    --build-arg "CORE_VARIANT=${CORE_VARIANT}" \
    -f "${DOCKERFILE}" \
    .

echo
echo "Built artifact for ${ARCH}/${PROFILE}:"
ls -l "${OUT_DIR}/fractalsql${OUTPUT_SUFFIX}.so"
file "${OUT_DIR}/fractalsql${OUTPUT_SUFFIX}.so" 2>/dev/null || true
