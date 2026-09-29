# SPDX-License-Identifier: GPL-3.0-only
# Thin wrapper; the logic lives in scripts/apply-patches.mjs (same code as scripts/apply-patches.sh).
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
node scripts/apply-patches.mjs @args
exit $LASTEXITCODE
