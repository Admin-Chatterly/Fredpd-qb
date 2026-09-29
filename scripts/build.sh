#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Thin wrapper; the logic lives in scripts/build.mjs so Windows (scripts/build.ps1) runs the same code.
set -euo pipefail
cd "$(dirname "$0")/.."
exec node scripts/build.mjs "$@"
