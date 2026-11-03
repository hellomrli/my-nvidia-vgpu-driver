#!/usr/bin/env bash
# Resolve current Unraid channels and compare both NVIDIA series with Releases.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nvidia-ci.py" check
