# SPDX-License-Identifier: GPL-3.0-only
# Thin wrapper; the logic lives in scripts/patch-server.mjs (same code as scripts/patch-server.sh).
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
node scripts/patch-server.mjs @args
exit $LASTEXITCODE
