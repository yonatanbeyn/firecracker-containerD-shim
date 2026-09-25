<#
.SYNOPSIS
    Sets up Firecracker inside WSL2 and boots a verification microVM.

.DESCRIPTION
    Windows-side entry point. Runs the preflight, install, rootfs build and
    network scripts inside the WSL2 distro as root, then runs a smoke test
    that boots a real microVM and verifies it over SSH.

    Idempotent - safe to re-run.

.PARAMETER Distro
    WSL distro to use. Defaults to Ubuntu.

.PARAMETER SkipSmokeTest
    Set up everything but do not boot the verification microVM.

.EXAMPLE
    .\setup.ps1
.EXAMPLE
    .\setup.ps1 -Distro Ubuntu -SkipSmokeTest
#>
[CmdletBinding()]
param(
    [string] $Distro = 'Ubuntu',
    [switch] $SkipSmokeTest
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  ok $msg"     -ForegroundColor Green }
function Write-Fail($msg) { Write-Host "FAIL $msg"     -ForegroundColor Red }

Write-Step "Firecracker on WSL2 - setup"

# --- Verify the distro exists -------------------------------------------------
# wsl.exe emits UTF-16; normalise before matching or the comparison never hits.
$prevEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::Unicode
try {
    $distros = (wsl.exe --list --quiet) -split "`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' }
} finally {
    [Console]::OutputEncoding = $prevEncoding
}

if ($distros -notcontains $Distro) {
    Write-Fail "WSL distro '$Distro' not found. Available: $($distros -join ', ')"
    Write-Host "Install one with: wsl --install -d Ubuntu" -ForegroundColor Yellow
    exit 1
}
Write-Ok "using WSL distro '$Distro'"

# --- Translate this folder to a WSL path --------------------------------------
# wsl.exe consumes backslashes as escapes when forwarding args to Linux, so
# hand wslpath a forward-slash path instead.
$winPath = $PSScriptRoot -replace '\\', '/'
$wslScriptDir = "$(wsl.exe -d $Distro -- wslpath -u "$winPath")".Trim()
if (-not $wslScriptDir) {
    Write-Fail "could not translate '$PSScriptRoot' to a WSL path"
    exit 1
}
Write-Ok "scripts at $wslScriptDir/scripts"

# --- Run a stage as root inside WSL -------------------------------------------
function Invoke-WslStage {
    param(
        [Parameter(Mandatory)] [string]   $Script,
        [string[]] $ScriptArgs = @()
    )
    # -u root avoids needing a sudo password inside WSL.
    & wsl.exe -d $Distro -u root -- bash "$wslScriptDir/scripts/$Script" @ScriptArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "$Script exited with code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

Write-Step "1/4 Preflight"
Invoke-WslStage '01-preflight.sh'

Write-Step "2/4 Install Firecracker + guest kernel"
Invoke-WslStage '02-install.sh'

Write-Step "3/4 Build guest rootfs"
Invoke-WslStage '03-build-rootfs.sh'

Write-Step "4/4 Configure host networking"
Invoke-WslStage '04-network.sh'

if ($SkipSmokeTest) {
    Write-Step "Setup complete (smoke test skipped)"
    Write-Host "Boot a microVM with: .\run.ps1" -ForegroundColor Yellow
    exit 0
}

Write-Step "Smoke test - booting a real microVM"
Invoke-WslStage '05-run-microvm.sh' @('--smoke')

Write-Step "Done"
Write-Host "Interactive console:  .\run.ps1"          -ForegroundColor Yellow
Write-Host "Re-run verification:  .\run.ps1 -Smoke"   -ForegroundColor Yellow
Write-Host ""
Write-Host "For Lambda-style microVMs that run OCI images (firecracker-containerd):" -ForegroundColor Yellow
Write-Host "  .\lambda.ps1 -Setup" -ForegroundColor Yellow
