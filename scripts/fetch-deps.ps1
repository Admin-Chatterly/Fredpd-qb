# SPDX-License-Identifier: GPL-3.0-only
# Thin wrapper; the logic lives in scripts/fetch-deps.mjs (same code as scripts/fetch-deps.sh).
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
node scripts/fetch-deps.mjs @args
exit $LASTEXITCODE
