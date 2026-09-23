#!/usr/bin/env bash
# =============================================================================
# publish-run-mirror.sh - publish official NVIDIA .run installers as assets of a
# dedicated GitHub release, so the cloud build has a download source that is not
# behind an anti-bot challenge.
#
# Why this exists: since 2026-09 the public alist share
# (https://alist.homelabproject.cc/foxipan/vGPU/) answers every download path
# (/d/, /p/, /dav/) with a CrowdSec challenge page over HTTP 200, so the build
# saved ~300 KiB of HTML instead of the 340 MB installer and then died on the
# pinned SHA256 check. build-nvidia-driver.sh now falls back to
#   https://github.com/<RUN_MIRROR_REPO>/releases/download/<RUN_MIRROR_TAG>/<asset>
# with asset names grid-<gridver>.run and vgpu-kvm-<version>.run.
#
# Usage:
#   scripts/publish-run-mirror.sh downloads/grid-535.309.01.run \
#                                    downloads/vgpu-kvm-535.309.01.run
#
# Env:
#   RUN_MIRROR_REPO  owner/repo (default: the origin remote)
#   RUN_MIRROR_TAG   release tag (default: sources)
#
# Requires the GitHub CLI (gh) authenticated with write access to the repo.
#
# NOTE: the assets are NVIDIA proprietary binaries. GRID/vGPU is licensed under
# terms that normally forbid redistribution - make sure you are allowed to host
# them before you publish, or point the build at a private location instead
# (GRID_RUN_URL / VGPU_RUN_URL).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_MIRROR_TAG="${RUN_MIRROR_TAG:-sources}"

log() { printf '[publish-run-mirror] %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "Missing required command: gh (https://cli.github.com)"

if [ -z "${RUN_MIRROR_REPO:-}" ]; then
  RUN_MIRROR_REPO="$(cd "$ROOT_DIR" && git remote get-url origin 2>/dev/null \
    | sed -E 's#(git@|https://)github.com[:/]##; s#\.git$##' || true)"
fi
[ -n "$RUN_MIRROR_REPO" ] || die "Cannot determine the repo - set RUN_MIRROR_REPO=owner/repo"
log "Target: $RUN_MIRROR_REPO release '$RUN_MIRROR_TAG'"

# default to everything already downloaded by a previous build
if [ "$#" -eq 0 ]; then
  set -- "$ROOT_DIR"/downloads/*.run
  [ -e "$1" ] || die "No .run files given and none found in $ROOT_DIR/downloads"
fi

# the asset name is what build-nvidia-driver.sh requests, so it must be canonical
files=()
for f in "$@"; do
  [ -s "$f" ] || die "Missing or empty file: $f"
  base="$(basename "$f")"
  case "$base" in
    grid-*.run|vgpu-kvm-*.run) ;;
    *) die "Asset must be named grid-<gridver>.run or vgpu-kvm-<version>.run (got '$base').
Rename or link it first, e.g.:  ln -s \"$base\" \"$(dirname "$f")/grid-<gridver>.run\"" ;;
  esac
  size="$(wc -c < "$f")"
  [ "$size" -ge 10485760 ] || die "$base is only ${size} bytes - that is not an installer"
  printf '%s  %s\n' "$(sha256sum "$f" | awk '{print $1}')" "$base"
  files+=("$f")
done

if ! gh release view "$RUN_MIRROR_TAG" --repo "$RUN_MIRROR_REPO" >/dev/null 2>&1; then
  log "Creating release '$RUN_MIRROR_TAG'"
  gh release create "$RUN_MIRROR_TAG" --repo "$RUN_MIRROR_REPO" \
    --title "Source mirror (.run installers - do not install)" \
    --notes "Official NVIDIA .run installers used as build inputs by .github/workflows/build-nvidia.yml.

These are **build sources, not installable packages** - the driver packages for
Unraid live in the kernel-tagged releases (e.g. \`6.18.52-Unraid\`).

The public alist share behind these files started answering automated downloads
with a CrowdSec challenge page, so the cloud build fetches them from here
instead (verified against the pinned SHA256 in scripts/build-nvidia-driver.sh)." \
    --latest=false
fi

log "Uploading ${#files[@]} asset(s) (existing assets with the same name are replaced)"
gh release upload "$RUN_MIRROR_TAG" "${files[@]}" --repo "$RUN_MIRROR_REPO" --clobber

log "Done. The build now resolves:"
for f in "${files[@]}"; do
  base="$(basename "$f")"
  log "  https://github.com/${RUN_MIRROR_REPO}/releases/download/${RUN_MIRROR_TAG}/${base}"
done
