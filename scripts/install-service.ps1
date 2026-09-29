# SPDX-License-Identifier: GPL-3.0-only
<#
.SYNOPSIS
  Installs (or updates) fredpd_service as a Windows service with NSSM (docs/hosting.md section 6, task 7.2).

.DESCRIPTION
  Idempotent: run it again after an update or to change a setting. An existing service is stopped, every NSSM setting
  is written again and the service is started (unless -NoStart). Nothing else on the machine is changed, apart from
  the folders and ACLs listed below.

  What it does:
    1. checks node, nssm, apps\service\.env, apps\service\node_modules\tsx and (warning only) apps\portal\dist;
    2. creates the log folder and apps\service\data, and - for a service account other than LocalSystem - grants that
       account Modify on both and Read on .env (inheritance removed from .env: Administrators, SYSTEM, account);
    3. nssm install (first run) and nssm set for: node --import tsx src/main.ts in apps\service, delayed auto start,
       dependency on the MariaDB service, NODE_ENV=production, log file with rotation (10 MB), restart on exit after
       5 s, Ctrl+C stop with 10 s grace, and the account;
    4. starts the service and prints nssm status.

  The account must hold "Log on as a service" (secpol.msc; error 1069 otherwise). The script does not create the
  account: see docs/hosting.md section 6 step 3.

.PARAMETER RepoRoot
  The FredPD checkout (the folder with apps\service). Default: the parent of this script's folder.
.PARAMETER LogDir
  Where fredpd_service.log is written. Default: C:\FredPD\logs.
.PARAMETER ServiceName
  Windows service name. Default: fredpd_service.
.PARAMETER Account
  Service account, e.g. .\fredpd-svc. Empty = LocalSystem (not recommended).
.PARAMETER Password
  Password of -Account (asked for when -Account is set and this is omitted).
.PARAMETER NodePath
  node.exe. Default: the node on PATH.
.PARAMETER NssmPath
  nssm.exe. Default: the nssm on PATH.
.PARAMETER DependOn
  Services that must run first. Default: MariaDB. Pass @() when MariaDB runs elsewhere.
.PARAMETER NoStart
  Configure only; do not start the service.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\install-service.ps1 -Account .\fredpd-svc
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$LogDir = 'C:\FredPD\logs',
    [string]$ServiceName = 'fredpd_service',
    [string]$Account = '',
    [SecureString]$Password,
    [string]$NodePath = '',
    [string]$NssmPath = '',
    [string[]]$DependOn = @('MariaDB'),
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

function Fail([string]$message) {
    Write-Error $message
    exit 1
}

function Resolve-Tool([string]$given, [string]$name) {
    if ($given) {
        if (-not (Test-Path -LiteralPath $given -PathType Leaf)) { Fail "$name not found at $given" }
        return (Resolve-Path -LiteralPath $given).Path
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) { Fail "$name is not on PATH; pass -$($name.Substring(0,1).ToUpper() + $name.Substring(1))Path" }
    return $cmd.Source
}

# --- 0. Administrator -------------------------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'Run this script in an elevated PowerShell (Run as administrator).'
}

# --- 1. Checks ----------------------------------------------------------------------------------------------------
$node = Resolve-Tool $NodePath 'node'
$nssm = Resolve-Tool $NssmPath 'nssm'
$serviceDir = Join-Path $RepoRoot 'apps\service'
$envFile = Join-Path $serviceDir '.env'
$dataDir = Join-Path $serviceDir 'data'
$logFile = Join-Path $LogDir "$ServiceName.log"

if (-not (Test-Path -LiteralPath (Join-Path $serviceDir 'src\main.ts'))) { Fail "apps\service not found under $RepoRoot (-RepoRoot)" }
if (-not (Test-Path -LiteralPath $envFile)) { Fail "$envFile is missing: copy apps\service\.env.example to .env and fill it in (docs/hosting.md section 6 step 1)" }
if (-not (Test-Path -LiteralPath (Join-Path $serviceDir 'node_modules\tsx'))) { Fail "tsx is not installed in apps\service: run pnpm install in $RepoRoot" }
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'apps\portal\dist\index.html'))) {
    Write-Warning 'apps\portal\dist is missing: the portal pages are not served until you run pnpm build (the API works).'
}
$nodeVersion = (& $node --version)
if ($nodeVersion -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 22) { Fail "node $nodeVersion is too old; FredPD needs Node 22 or newer" }

$plainPassword = $null
if ($Account) {
    if (-not $Password) { $Password = Read-Host -AsSecureString "Password for $Account" }
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
}

# --- 2. Folders and ACLs ------------------------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $LogDir, $dataDir | Out-Null
if ($Account) {
    $who = $Account -replace '^\.\\', "$env:COMPUTERNAME\"
    & icacls $LogDir /grant "${who}:(OI)(CI)M" | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "icacls could not give $Account write access to $LogDir (exit $LASTEXITCODE; does the account exist?)" }
    & icacls $dataDir /grant "${who}:(OI)(CI)M" | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "icacls could not give $Account write access to $dataDir (exit $LASTEXITCODE; does the account exist?)" }
    & icacls $envFile /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' "${who}:R" | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "icacls failed for $envFile (does the account $Account exist?)" }
}

# --- 3. NSSM ------------------------------------------------------------------------------------------------------
function Invoke-Nssm {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NssmArgs)
    & $nssm @NssmArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "nssm $($NssmArgs[0]) $($NssmArgs[1]) $($NssmArgs[2]) failed (exit $LASTEXITCODE)" }
}

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Updating $ServiceName"
    if ($existing.Status -ne 'Stopped') {
        & $nssm stop $ServiceName | Out-Null
        $stopCode = $LASTEXITCODE
        $existing.Refresh()
        if ($stopCode -ne 0 -and $existing.Status -ne 'Stopped') {
            Fail "nssm stop $ServiceName failed (exit $stopCode, status $($existing.Status)); stop it by hand and run this script again"
        }
    }
    Invoke-Nssm set $ServiceName Application $node
} else {
    Write-Host "Installing $ServiceName"
    Invoke-Nssm install $ServiceName $node
}

Invoke-Nssm set $ServiceName AppParameters '--import tsx src/main.ts'
Invoke-Nssm set $ServiceName AppDirectory $serviceDir
Invoke-Nssm set $ServiceName DisplayName 'FredPD service'
Invoke-Nssm set $ServiceName Description 'FredPD portal, portal API, Discord bot and FXServer bridge'
Invoke-Nssm set $ServiceName Start SERVICE_DELAYED_AUTO_START
if ($DependOn.Count -gt 0) {
    foreach ($dep in $DependOn) {
        if (-not (Get-Service -Name $dep -ErrorAction SilentlyContinue)) { Write-Warning "dependency service '$dep' does not exist on this machine" }
    }
    Invoke-Nssm set $ServiceName DependOnService @DependOn
} else {
    Invoke-Nssm reset $ServiceName DependOnService
}
Invoke-Nssm set $ServiceName AppEnvironmentExtra 'NODE_ENV=production'
Invoke-Nssm set $ServiceName AppStdout $logFile
Invoke-Nssm set $ServiceName AppStderr $logFile
Invoke-Nssm set $ServiceName AppRotateFiles 1
Invoke-Nssm set $ServiceName AppRotateOnline 1
Invoke-Nssm set $ServiceName AppRotateBytes 10485760
Invoke-Nssm set $ServiceName AppExit Default Restart
Invoke-Nssm set $ServiceName AppRestartDelay 5000
Invoke-Nssm set $ServiceName AppStopMethodConsole 10000
if ($Account) {
    & $nssm set $ServiceName ObjectName $Account $plainPassword | Out-Null
    $code = $LASTEXITCODE
    $plainPassword = $null
    if ($code -ne 0) { Fail "nssm could not set the account $Account (wrong password?)" }
} else {
    Write-Warning 'No -Account: the service runs as LocalSystem. docs/hosting.md section 6 step 3 creates fredpd-svc.'
    Invoke-Nssm set $ServiceName ObjectName LocalSystem
}

# --- 4. Start -----------------------------------------------------------------------------------------------------
if ($NoStart) {
    Write-Host "$ServiceName configured (not started: -NoStart)."
    exit 0
}
& $nssm start $ServiceName | Out-Null
Start-Sleep -Seconds 3
$status = (& $nssm status $ServiceName)
Write-Host "$ServiceName status: $status"
if ($status -notmatch 'SERVICE_RUNNING') {
    Write-Warning "Not running. Check $logFile and docs/hosting.md section 11 (error 1069 = missing 'Log on as a service')."
    exit 1
}
Write-Host "Check: curl.exe -s http://127.0.0.1:3000/api/session"
