#!/usr/bin/env bash
# Thin wrapper; the logic lives in scripts/build.mjs so Windows (scripts/build.ps1) runs the same code.
set -euo pipefail
cd "$(dirname "$0")/.."
exec node scripts/build.mjs "$@"
