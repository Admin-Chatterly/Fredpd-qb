# SPDX-License-Identifier: GPL-3.0-only
# Thin wrapper; the logic lives in scripts/build.mjs (same code as scripts/build.sh).
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
node scripts/build.mjs @args
exit $LASTEXITCODE
