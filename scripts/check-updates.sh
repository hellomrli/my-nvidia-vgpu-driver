#!/usr/bin/env bash
# =============================================================================
# check-updates.sh - check for newer NVIDIA vGPU 16.x and Unraid kernel releases.
#
# Two update sources:
#   1. Official vGPU 16 line on the alist mirror
#        https://alist.homelabproject.cc/foxipan/vGPU/<16.x>/
#      A newer 16.x branch (or a newer driver inside the current branch) means
#      a new NVIDIA vGPU driver.
#   2. ich777/unraid_kernel GitHub releases
#      A newer tag (e.g. 6.18.45-Unraid) means a new Unraid kernel to build for.
#
# When run inside GitHub Actions with GITHUB_TOKEN set, it also decides whether
# a build is actually needed (by comparing against the driver repo's existing
# Releases) and emits a machine-readable JSON result. It does NOT trigger the
# build itself - the caller (check-updates.yml) does that.
#
# Output (JSON on stdout):
#   {
#     "vgpu_branch": "16.14",
#     "driver_version": "535.309.01",
#     "windows_version": "539.72",
#     "kernel_release": "6.18.45-Unraid",
#     "build_needed": true,
#     "reason": "new kernel (no release)"
#   }
# =============================================================================
set -euo pipefail

ALIST_API="${ALIST_API:-https://alist.homelabproject.cc/api/fs/list}"
VGPU_PATH="${VGPU_PATH:-/foxipan/vGPU}"
KERNEL_REPO="${KERNEL_REPO:-ich777/unraid_kernel}"
# Only the vGPU 16 major line is tracked (matching this project's target).
VGPU_MAJOR="${VGPU_MAJOR:-16}"

log() { printf '[check-updates] %s\n' "$*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing $1"; exit 1; }; }

# ---------- 1. latest vGPU 16.x branch + driver/windows version ----------
need_cmd curl
need_cmd jq

log "Listing vGPU branches under $VGPU_PATH"
branch_list="$(curl -fsS --retry 3 --retry-delay 2 "$ALIST_API?path=$VGPU_PATH")"
latest_branch="$(printf '%s' "$branch_list" \
  | jq -r --arg m "$VGPU_MAJOR" '.data.content[] | select(.is_dir) | .name | select(test("^" + $m + "\\."))' \
  | sort -V | tail -1)"
if [ -z "$latest_branch" ]; then
  log "ERROR: no vGPU $VGPU_MAJOR.x branch found on the alist mirror"
  exit 1
fi
log "Latest vGPU branch: $latest_branch"

pkg_dir="$(curl -fsS --retry 3 --retry-delay 2 "$ALIST_API?path=$VGPU_PATH/$latest_branch" \
  | jq -r '.data.content[] | select(.is_dir) | .name' \
  | grep '^NVIDIA-GRID-Linux-KVM-' | head -1)"
if [ -z "$pkg_dir" ]; then
  log "ERROR: no NVIDIA-GRID-Linux-KVM-* dir under $latest_branch"
  exit 1
fi

# pkg_dir = NVIDIA-GRID-Linux-KVM-<driver>-<winver>
driver_version="$(printf '%s' "$pkg_dir" | sed -E 's/^NVIDIA-GRID-Linux-KVM-([0-9.]+)-[0-9.]+$/\1/')"
windows_version="$(printf '%s' "$pkg_dir" | sed -E 's/^NVIDIA-GRID-Linux-KVM-[0-9.]+-([0-9.]+)$/\1/')"
log "Latest driver: $driver_version (windows $windows_version, dir $pkg_dir)"

# ---------- 2. latest ich777/unraid_kernel release ----------
log "Querying $KERNEL_REPO releases"
# GitHub API can transiently 504/503; retry a few times with a pause, then
# give up gracefully (the next daily run will pick it up).
latest_kernel=""
for attempt in 1 2 3 4 5; do
  latest_kernel="$(curl -sS --retry 2 --retry-delay 3 \
    "https://api.github.com/repos/$KERNEL_REPO/releases?per_page=1" \
    | jq -r '.[0].tag_name // empty' 2>/dev/null || true)"
  [ -n "$latest_kernel" ] && break
  log "kernel release query failed (attempt $attempt), retrying in 10s"
  sleep 10
done
if [ -z "$latest_kernel" ]; then
  log "ERROR: could not read latest kernel release tag after retries"
  exit 1
fi
log "Latest kernel: $latest_kernel"

# ---------- 3. decide whether a build is needed ----------
build_needed="false"
reason="up-to-date"

if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  log "Comparing against existing Releases in $GITHUB_REPOSITORY"
  # 404 = this kernel has no release yet (legitimate "build needed" signal);
  # 5xx = transient API failure (do NOT misjudge as needing a build).
  code="$(curl -sS -o /tmp/rel.json -w '%{http_code}' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/tags/$latest_kernel" 2>/dev/null || true)"

  if [ "$code" = "200" ]; then
    # release exists; check whether it already carries this driver version
    has_driver="$(jq -r --arg d "$driver_version" \
      '.assets[].name | select(startswith("nvidia-" + $d + "-")) | .' /tmp/rel.json 2>/dev/null | head -1 || true)"
    if [ -z "$has_driver" ]; then
      build_needed="true"
      reason="new driver $driver_version for $latest_kernel (not in release)"
    fi
  elif [ "$code" = "404" ]; then
    build_needed="true"
    reason="new kernel $latest_kernel (no release)"
  else
    reason="release check failed (http $code); will retry next run"
  fi
else
  # without GitHub context we cannot compare; report the latest and let the caller decide
  reason="unknown (no GITHUB_TOKEN/repository)"
fi

jq -n \
  --arg b "$latest_branch" \
  --arg d "$driver_version" \
  --arg w "$windows_version" \
  --arg k "$latest_kernel" \
  --arg bn "$build_needed" \
  --arg r "$reason" \
  '{vgpu_branch: $b, driver_version: $d, windows_version: $w, kernel_release: $k, build_needed: $bn, reason: $r}'

log "Result: build_needed=$build_needed ($reason)"
