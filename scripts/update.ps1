# SPDX-License-Identifier: GPL-3.0-only
# Thin wrapper; the logic lives in scripts/update.mjs (same code as scripts/update.sh).
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
node scripts/update.mjs @args
exit $LASTEXITCODE
