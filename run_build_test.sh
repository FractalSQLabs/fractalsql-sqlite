#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# run_build_test.sh — containerized wrapper around build_test.sh.
# build_test.sh runs INSIDE a throwaway container against the mounted
# repo, so a clean container exit IS the test passing — no separate
# `docker run` / cleanup dance needed.
#
# Deliberately simple (single axis: PROFILE). Each base image pins its
# own toolchain/glibc, so there's no separate libc/arch/profile matrix
# to manage here:
#
#   modern  — rockylinux:9 (glibc 2.34, the default packaging target)
#   legacy  — quay.io/pypa/manylinux_2_28_x86_64 (glibc 2.28 floor)
#   musl    — alpine:3.20
#
# Usage:
#   ./run_build_test.sh                      # modern, sequential
#   ./run_build_test.sh --profile musl       # one profile only
#   ./run_build_test.sh legacy musl          # explicit profiles
#   ./run_build_test.sh --profile modern --asan   # sanitizer flags
#                                             # passed through to
#                                             # build_test.sh (Linux
#                                             # only — the sanitized
#                                             # .so needs its runtime
#                                             # preloaded)
#
# Prereqs: docker (bind-mount capable; nothing is baked into the image —
# the repo is mounted read-write at /work).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

if [[ -t 1 ]]; then G="\033[32m"; R="\033[31m"; Z="\033[0m"; else G=""; R=""; Z=""; fi

SAN_MODE=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --asan)    SAN_MODE="asan" ;;
    --ubsan)   SAN_MODE="ubsan" ;;
    *)         ARGS+=("$1") ;;
  esac
  shift
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not on PATH." >&2
  exit 2
fi

# Per-profile: base image + the minimal package set build_test.sh's
# gates need (cc, make, the sqlite3 CLI, python3, bash itself on musl).
IMG_modern="rockylinux:9"
PRE_modern="dnf install -y --setopt=install_weak_deps=False gcc make sqlite python3 diffutils >/dev/null && "

IMG_legacy="quay.io/pypa/manylinux_2_28_x86_64"
PRE_legacy="yum install -y sqlite python3 >/dev/null || true && "

IMG_musl="alpine:3.20"
PRE_musl="apk add --no-cache bash gcc make sqlite sqlite-dev python3 >/dev/null && "

PROFILES=(modern)
if [[ "${1:-}" = "--profile" ]]; then
  PROFILES=("$2")
elif [[ $# -gt 0 ]]; then
  PROFILES=("$@")
fi

# --asan/--ubsan are build_test.sh flags — forwarded verbatim.
FWD=()
[[ -n "$SAN_MODE" ]] && FWD+=("--$SAN_MODE")

FAILED=0
for v in "${PROFILES[@]}"; do
  img_var="IMG_$v"; pre_var="PRE_$v"
  if [[ -z "${!img_var:-}" ]]; then
    echo "ERROR: unknown profile '$v' (modern | legacy | musl)" >&2
    exit 2
  fi
  echo ""
  echo "== docker build_test ${v} (${!img_var}) =="
  if docker run --rm \
       -v "$HERE":/work -w /work \
       -e "FSQL_TEST_TIMEOUT_MULT=${FSQL_TEST_TIMEOUT_MULT:-1}" \
       "${!img_var}" \
       bash -c "${!pre_var} ./build_test.sh ${FWD[@]+"${FWD[@]}"}" ; then
    printf "  [${G}PASS${Z}] %s\n" "$v"
  else
    printf "  [${R}FAIL${Z}] %s\n" "$v"
    FAILED=1
  fi
done

echo ""
if [[ "$FAILED" -eq 0 ]]; then printf "${G}run_build_test: PASS${Z}\n"; exit 0
else printf "${R}run_build_test: FAIL${Z}\n"; exit 1
fi