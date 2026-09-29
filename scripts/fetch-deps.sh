#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Thin wrapper; the logic lives in scripts/fetch-deps.mjs so Windows (scripts/fetch-deps.ps1) runs the same code.
set -euo pipefail
cd "$(dirname "$0")/.."
exec node scripts/fetch-deps.mjs "$@"
