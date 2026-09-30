# SPDX-License-Identifier: GPL-3.0-only
# One-time setup (docs/dev-loop.md): point the FXServer resources folder at this clone with directory junctions, so
# `scripts/update.ps1` updates the running server without copying anything. Existing folders are moved to a backup
# (never deleted). Run from an elevated or normal PowerShell; junctions need no admin rights on NTFS.
#
#   .\scripts\link-server.ps1 -ServerResources "C:\Users\FiveM\Desktop\SalamDevQB\resources"
#   .\scripts\link-server.ps1 -ServerResources "..." -Upstream qb-policejob,ps-dispatch -WhatIf
#
# -Upstream: OPTIONAL patched upstream resources to run from resources\[upstream] (default: none). Normally don't:
# that replaces your configured copy (doors, locations, items). Use scripts\patch-server.ps1 instead, which patches
# your own copies in place. Each is found wherever it currently sits under -ServerResources (e.g. [qb]\qb-policejob) and replaced by a
# junction to the patched checkout; the original folder is renamed to <name>.bak-<timestamp> (move it out of
# resources\ afterwards, or FXServer warns about duplicates).
param(
    [Parameter(Mandatory = $true)][string]$ServerResources,
    [string[]]$Upstream = @(),
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not (Test-Path $ServerResources)) { throw "Not found: $ServerResources" }

function Test-Junction([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Set-Junction([string]$Link, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Target)) { throw "Target missing: $Target (run scripts\fetch-deps.ps1 and scripts\apply-patches.ps1 first)" }
    if (Test-Junction $Link) {
        Write-Host "ok     $Link (already a junction)"
        return
    }
    if (Test-Path -LiteralPath $Link) {
        $backup = "$Link.bak-$stamp"
        Write-Host "backup $Link -> $backup"
        if (-not $WhatIf) { Rename-Item -LiteralPath $Link -NewName (Split-Path $backup -Leaf) }
    }
    Write-Host "link   $Link -> $Target"
    if (-not $WhatIf) { New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null }
}

# 1. FredPD's own resources: the whole [fredpd] folder.
Set-Junction (Join-Path $ServerResources '[fredpd]') (Join-Path $repo 'resources\[fredpd]')

# 2. Patched upstream resources: replace the server's copy wherever it is.
foreach ($name in $Upstream) {
    $target = Join-Path $repo "resources\[upstream]\$name"
    $existing = Get-ChildItem -LiteralPath $ServerResources -Directory -Recurse -Depth 2 -Filter $name -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\[upstream]\*' -and $_.FullName -notlike '*.bak-*' } | Select-Object -First 1
    $link = if ($existing) { $existing.FullName } else { Join-Path $ServerResources "[standalone]\$name" }
    Set-Junction $link $target
}

# 3. A copied [upstream] folder on the server causes duplicate-resource warnings.
$dup = Join-Path $ServerResources '[upstream]'
if ((Test-Path -LiteralPath $dup) -and -not (Test-Junction $dup)) {
    Write-Warning "$dup exists on the server: delete it (FredPD links the patched folders individually)."
}
Write-Host "`nDone. Add to server.cfg if missing:  ensure fredpd_reloader   (and on a test server: set fredpd_dev true / ensure fredpd_devtools)"
