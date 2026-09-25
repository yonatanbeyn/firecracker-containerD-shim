<#
.SYNOPSIS
    Boots a Firecracker microVM in WSL2.

.DESCRIPTION
    Attaches to the guest serial console by default. Requires setup.ps1 to have
    been run at least once.

.PARAMETER Smoke
    Boot, verify the guest over SSH, print a report and shut down. Non-interactive.

.PARAMETER Ssh
    SSH into an already-running microVM from another window.

.PARAMETER Distro
    WSL distro to use. Defaults to Ubuntu.

.EXAMPLE
    .\run.ps1
.EXAMPLE
    .\run.ps1 -Smoke
.EXAMPLE
    .\run.ps1 -Ssh
#>
[CmdletBinding()]
param(
    [switch] $Smoke,
    [switch] $Ssh,
    [string] $Distro = 'Ubuntu'
)

$ErrorActionPreference = 'Stop'

# wsl.exe consumes backslashes as escapes when forwarding args to Linux, so
# hand wslpath a forward-slash path instead.
$winPath = $PSScriptRoot -replace '\\', '/'
$wslScriptDir = "$(wsl.exe -d $Distro -- wslpath -u "$winPath")".Trim()
if (-not $wslScriptDir) {
    Write-Host "FAIL could not translate '$PSScriptRoot' to a WSL path" -ForegroundColor Red
    exit 1
}

if ($Ssh) {
    Write-Host "Connecting to the running microVM at 172.16.0.2 ..." -ForegroundColor Cyan
    & wsl.exe -d $Distro -u root -- ssh `
        -i /srv/firecracker/keys/id_ed25519 `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=/dev/null `
        -o LogLevel=ERROR `
        root@172.16.0.2
    exit $LASTEXITCODE
}

$fcArgs = @()
if ($Smoke) { $fcArgs += '--smoke' }

& wsl.exe -d $Distro -u root -- bash "$wslScriptDir/scripts/05-run-microvm.sh" @fcArgs
exit $LASTEXITCODE
