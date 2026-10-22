#!/usr/bin/env bash
# =============================================================================
# check-updates.sh - check for newer NVIDIA vGPU releases and Unraid kernels.
#
# Two update sources:
#   1. Official vGPU branches on the alist mirror
#        https://alist.homelabproject.cc/foxipan/vGPU/<major>.<minor>/
#      EVERY tracked major line (VGPU_MAJORS, default "16 19" = the 535.x and
#      580.x series) is resolved to its newest branch and package dir. Tracking
#      only the first line used to leave every new kernel with a 16.x package
#      and no 19.x one until someone dispatched it by hand.
#   2. ich777/unraid_kernel GitHub releases
#      A newer tag (e.g. 6.18.58-Unraid) means a new Unraid kernel to build for.
#
# When run inside GitHub Actions with GITHUB_TOKEN set, it also decides which
# builds are actually needed (comparing each line against the driver repo's
# existing Releases) and emits a machine-readable JSON result. It does NOT
# trigger the builds itself - the caller (check-updates.yml) dispatches one
# build per entry in "builds".
#
# Output (JSON on stdout):
#   {
#     "kernel_release": "6.18.58-Unraid",
#     "build_needed": true,
#     "reason": "16: up-to-date; 19: missing nvidia-580.178.05-* for 6.18.58-Unraid",
#     "lines":  [ {major, vgpu_branch, driver_version, windows_version, alist_pkg_dir}, ... ],
#     "builds": [ {major, vgpu_branch, driver_version, windows_version,
#                  alist_pkg_dir, kernel_release, reason}, ... ]
#   }
# =============================================================================
set -euo pipefail

ALIST_API="${ALIST_API:-https://alist.homelabproject.cc/api/fs/list}"
VGPU_PATH="${VGPU_PATH:-/foxipan/vGPU}"
KERNEL_REPO="${KERNEL_REPO:-ich777/unraid_kernel}"
# vGPU major lines to track: 16 = 535.x (16.14 LTS), 19 = 580.x
VGPU_MAJORS="${VGPU_MAJORS:-16 19}"

log() { printf '[check-updates] %s\n' "$*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing $1"; exit 1; }; }

# GET a GitHub API URL, authenticated whenever a token is available.
# Unauthenticated calls are capped at 60 requests/hour *per IP* and
# GitHub-hosted runners share their egress IPs, so the daily check used to end
# up with an opaque empty result (5 silent retries, then a red run). On failure
# this logs the HTTP status and the API message instead of returning nothing.
gh_api() {
  local url="$1" body status
  local -a auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  body="$(mktemp)"
  status="$(curl -sS -o "$body" -w '%{http_code}' --connect-timeout 10 --max-time 30 \
            ${auth[@]+"${auth[@]}"} "$url" || true)"
  if [ "$status" != "200" ]; then
    log "GitHub API HTTP ${status:-none} for $url: $(head -c 200 "$body" 2>/dev/null | tr -d '\n')"
    rm -f "$body"
    return 1
  fi
  cat "$body"
  rm -f "$body"
}

# ---------- 1. newest branch + package dir for every tracked line ----------
need_cmd curl
need_cmd jq

log "Listing vGPU branches under $VGPU_PATH (lines: $VGPU_MAJORS)"
branch_list="$(curl -fsS --retry 3 --retry-delay 2 "$ALIST_API?path=$VGPU_PATH")"

lines="[]"
for major in $VGPU_MAJORS; do
  branch="$(printf '%s' "$branch_list" \
    | jq -r --arg m "$major" '.data.content[] | select(.is_dir) | .name | select(test("^" + $m + "\\."))' \
    | sort -V | tail -1)"
  if [ -z "$branch" ]; then
    log "WARNING: no vGPU $major.x branch on the mirror - line skipped"
    continue
  fi
  pkg_dir="$(curl -fsS --retry 3 --retry-delay 2 "$ALIST_API?path=$VGPU_PATH/$branch" \
    | jq -r '.data.content[] | select(.is_dir) | .name' \
    | grep '^NVIDIA-GRID-Linux-KVM-' | head -1 || true)"
  if [ -z "$pkg_dir" ]; then
    log "WARNING: no NVIDIA-GRID-Linux-KVM-* dir under $branch - line skipped"
    continue
  fi

  # NVIDIA-GRID-Linux-KVM-<driver>-<winver>          (16.x, two numbers)
  # NVIDIA-GRID-Linux-KVM-<driver>-<grid>-<winver>   (19.x, three numbers)
  # The exact directory name is handed to the build script, which derives the
  # grid version itself for the three-number form.
  driver_version="$(printf '%s' "$pkg_dir" | sed -E 's/^NVIDIA-GRID-Linux-KVM-([0-9.]+)-.*$/\1/')"
  # windows version = the last dash-separated component (works for both forms)
  windows_version="$(printf '%s' "$pkg_dir" | sed -E 's/.*-([0-9.]+)$/\1/')"
  log "vGPU $major line: branch $branch, driver $driver_version (windows $windows_version, dir $pkg_dir)"

  lines="$(jq -c --argjson l "$lines" --arg m "$major" --arg b "$branch" \
    --arg d "$driver_version" --arg w "$windows_version" --arg p "$pkg_dir" \
    '$l + [{major:$m, vgpu_branch:$b, driver_version:$d, windows_version:$w, alist_pkg_dir:$p}]' \
    <<<"$lines")"
done

if [ "$(jq 'length' <<<"$lines")" = "0" ]; then
  log "ERROR: no tracked vGPU line could be resolved on the mirror"
  exit 1
fi

# ---------- 2. latest ich777/unraid_kernel release ----------
log "Querying $KERNEL_REPO releases"
# GitHub API can transiently 504/503 or rate-limit the shared runner IPs; retry
# a few times with a pause, then give up gracefully (the next daily run will
# pick it up). gh_api logs the real reason for every failed attempt.
latest_kernel=""
for attempt in 1 2 3 4 5; do
  latest_kernel="$(gh_api "https://api.github.com/repos/$KERNEL_REPO/releases?per_page=1" \
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

# ---------- 3. which lines still need a package for that kernel ----------
builds="[]"
reasons=""

if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  log "Comparing against existing Releases in $GITHUB_REPOSITORY"
  # 404 = this kernel has no release yet (legitimate "build needed" signal);
  # 5xx = transient API failure (do NOT misjudge as needing a build).
  code="$(curl -sS -o /tmp/rel.json -w '%{http_code}' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/tags/$latest_kernel" 2>/dev/null || true)"

  if [ "$code" != "200" ] && [ "$code" != "404" ]; then
    reasons="release check failed (http $code); will retry next run"
    if [ -s /tmp/rel.json ]; then
      log "release check failed: http $code $(head -c 200 /tmp/rel.json | tr -d '\n')"
    fi
  else
    # one decision per tracked line: a release may already carry the 16.x
    # package while the 19.x one is still missing
    while IFS= read -r line; do
      major="$(jq -r '.major' <<<"$line")"
      driver="$(jq -r '.driver_version' <<<"$line")"
      has_driver=""
      if [ "$code" = "200" ]; then
        has_driver="$(jq -r --arg d "$driver" \
          '.assets[]?.name | select(startswith("nvidia-" + $d + "-")) | .' /tmp/rel.json 2>/dev/null \
          | head -1 || true)"
      fi
      if [ -n "$has_driver" ]; then
        log "vGPU $major line: already released ($has_driver)"
        reasons="${reasons}${major}: up-to-date; "
      else
        if [ "$code" = "404" ]; then
          why="new kernel $latest_kernel (no release)"
        else
          why="missing nvidia-${driver}-* for $latest_kernel"
        fi
        log "vGPU $major line: build needed - $why"
        builds="$(jq -c --argjson b "$builds" --argjson l "$line" \
          --arg k "$latest_kernel" --arg w "$why" \
          '$b + [$l + {kernel_release:$k, reason:$w}]' <<<"$builds")"
        reasons="${reasons}${major}: ${why}; "
      fi
    done < <(jq -c '.[]' <<<"$lines")
  fi
else
  # without GitHub context we cannot compare; report the lines and let the caller decide
  reasons="unknown (no GITHUB_TOKEN/repository)"
fi

build_needed="false"
if [ "$(jq 'length' <<<"$builds")" != "0" ]; then build_needed="true"; fi
reason="${reasons%; }"

jq -n --arg k "$latest_kernel" --arg bn "$build_needed" --arg r "$reason" \
  --argjson l "$lines" --argjson b "$builds" \
  '{kernel_release: $k, build_needed: ($bn == "true"), reason: $r, lines: $l, builds: $b}'

log "Result: build_needed=$build_needed (${reason})"
