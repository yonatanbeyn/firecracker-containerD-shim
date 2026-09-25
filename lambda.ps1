<#
.SYNOPSIS
    Runs OCI container images as Lambda-style Firecracker microVMs.

.DESCRIPTION
    Windows entry point for the firecracker-containerd layer. Each invocation
    boots a dedicated Firecracker microVM with its own kernel, runs the
    container inside it, and tears it down.

    Run -Setup once before anything else (it takes ~10 minutes: it compiles
    firecracker-containerd from source).

.PARAMETER Setup
    Build and configure the whole firecracker-containerd stack.

.PARAMETER Shell
    Open an interactive shell inside a microVM.

.PARAMETER Bench
    Boot N microVMs in sequence and report cold-start timings.

.PARAMETER Image
    OCI image to run. Defaults to alpine:3.20.

.PARAMETER Command
    Shell command to run inside the microVM.

.PARAMETER Status
    Show stack health without booting a VM.

.PARAMETER Service
    Run a long-lived service (default nginx) in a microVM and verify that the
    host can reach it over HTTP.

.PARAMETER Publish
    Also expose the service to Windows on http://localhost:<port>. Implies a
    persistent service.

.PARAMETER Stop
    Stop a running service and remove any publish relays.

.PARAMETER Distro
    WSL distro to use. Defaults to Ubuntu.

.EXAMPLE
    .\lambda.ps1 -Setup
.EXAMPLE
    .\lambda.ps1
.EXAMPLE
    .\lambda.ps1 -Shell
.EXAMPLE
    .\lambda.ps1 -Bench 5
.EXAMPLE
    .\lambda.ps1 -Image docker.io/library/python:3.12-alpine -Command 'python3 -c "print(2**100)"'
#>
[CmdletBinding()]
param(
    [switch] $Setup,
    [switch] $Shell,
    [int]    $Bench = 0,
    [string] $Image,
    [string] $Command,
    [switch] $Status,
    [switch] $Service,
    [int]    $Publish = 0,
    [switch] $Stop,
    [string] $Distro = 'Ubuntu'
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Fail($msg) { Write-Host "FAIL $msg"     -ForegroundColor Red }

# WSL2 shuts its VM down shortly after the last client session detaches, which
# kills any detached microVM and the container inside it. vmIdleTimeout=-1 in
# .wslconfig does NOT prevent this on WSL 2.4.11 (verified: the distro still
# restarted). Holding an actual session open does.
# Detected from inside the distro rather than by inspecting wsl.exe command
# lines on the Windows side, which are not reliably readable.
function Test-KeepAlive {
    $out = & wsl.exe -d $Distro -u root -- pgrep -x sleep 2>$null
    return [bool]($out -and "$out".Trim())
}

function Start-WslKeepAlive {
    if (Test-KeepAlive) {
        Write-Host "  ok WSL keepalive already running" -ForegroundColor Green
        return
    }
    # Args must stay quote-free: Start-Process flattens -ArgumentList into a
    # single string, so `sh -c "..."` loses its quoting and exits immediately.
    Start-Process -FilePath 'wsl.exe' -WindowStyle Hidden -ArgumentList @(
        '-d', $Distro, '-u', 'root', '--', 'sleep', 'infinity'
    )
    Start-Sleep -Seconds 3
    if (Test-KeepAlive) {
        Write-Host "  ok WSL keepalive started (holds the distro open)" -ForegroundColor Green
    } else {
        Write-Host "warn could not confirm WSL keepalive; the service may stop when WSL idles" -ForegroundColor Yellow
    }
}

function Stop-WslKeepAlive {
    if (-not (Test-KeepAlive)) {
        Write-Host "  ok no WSL keepalive running" -ForegroundColor Green
        return
    }
    # Killing it inside the distro also ends the attached wsl.exe client.
    & wsl.exe -d $Distro -u root -- pkill -x sleep 2>$null | Out-Null
    Write-Host "  ok WSL keepalive stopped" -ForegroundColor Green
}

# wsl.exe eats backslashes when forwarding args, so translate via forward slashes.
$winPath = $PSScriptRoot -replace '\\', '/'
$wslScriptDir = "$(wsl.exe -d $Distro -- wslpath -u "$winPath")".Trim()
if (-not $wslScriptDir) {
    Write-Fail "could not translate '$PSScriptRoot' to a WSL path"
    exit 1
}

function Invoke-WslStage {
    param(
        [Parameter(Mandatory)] [string] $Script,
        [string[]] $ScriptArgs = @()
    )
    & wsl.exe -d $Distro -u root -- bash "$wslScriptDir/scripts/$Script" @ScriptArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "$Script exited with code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

if ($Setup) {
    Write-Host "Building firecracker-containerd from source." -ForegroundColor Yellow
    Write-Host "First run takes ~10 minutes (Go toolchain + full dependency tree)." -ForegroundColor Yellow

    Write-Step "1/5 Base Firecracker layer"
    Invoke-WslStage '01-preflight.sh'
    Invoke-WslStage '02-install.sh'

    Write-Step "2/5 Build toolchain (Go, devmapper headers)"
    Invoke-WslStage '10-install-toolchain.sh'

    Write-Step "3/5 Build firecracker-containerd"
    Invoke-WslStage '11-build-firecracker-containerd.sh'

    Write-Step "4/5 Build guest agent rootfs"
    Invoke-WslStage '12-build-agent-rootfs.sh'

    Write-Step "5/5 Configure containerd, devmapper and CNI"
    Invoke-WslStage '13-configure-containerd.sh'

    Write-Step "Verifying with a real microVM"
    Invoke-WslStage '14-run-lambda-vm.sh'

    Write-Step "Done"
    Write-Host "Run a microVM:       .\lambda.ps1"                 -ForegroundColor Yellow
    Write-Host "Interactive shell:   .\lambda.ps1 -Shell"          -ForegroundColor Yellow
    Write-Host "Cold-start bench:    .\lambda.ps1 -Bench 5"        -ForegroundColor Yellow
    exit 0
}

if ($Status) {
    & wsl.exe -d $Distro -u root -- bash "$wslScriptDir/scripts/status.sh"
    exit $LASTEXITCODE
}

# Long-lived service in a microVM (15-run-service.sh)
if ($Service -or $Publish -gt 0 -or $Stop) {
    $svcArgs = @()
    if ($Stop)          { $svcArgs += '--stop' }
    if ($Publish -gt 0) { $svcArgs += @('--publish', "$Publish") }
    if ($Image)         { $svcArgs += @('--image', $Image) }

    # Start the keepalive BEFORE the VM, so the distro cannot idle out during
    # the (slow) image pull and boot.
    if (-not $Stop) { Start-WslKeepAlive }

    & wsl.exe -d $Distro -u root -- bash "$wslScriptDir/scripts/15-run-service.sh" @svcArgs
    $rc = $LASTEXITCODE

    if ($Stop) { Stop-WslKeepAlive }

    # Prove the Windows side of the path actually works, rather than just
    # reporting that a relay was started inside WSL.
    if ($rc -eq 0 -and $Publish -gt 0) {
        Write-Host "`n=== Verifying from Windows ===" -ForegroundColor Cyan
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$Publish/" -TimeoutSec 10 -UseBasicParsing
            Write-Host "  ok HTTP $($r.StatusCode) from Windows at http://localhost:$Publish/" -ForegroundColor Green
        } catch {
            Write-Host "FAIL not reachable from Windows: $($_.Exception.Message)" -ForegroundColor Red
            $rc = 1
        }
    }
    exit $rc
}

# Build args for 14-run-lambda-vm.sh
$fcArgs = @()
if ($Shell)                      { $fcArgs += '--shell' }
if ($Bench -gt 0)                { $fcArgs += @('--bench', "$Bench") }
if ($Image)                      { $fcArgs += @('--image', $Image) }
if ($PSBoundParameters.ContainsKey('Command')) { $fcArgs += @('--cmd', $Command) }

& wsl.exe -d $Distro -u root -- bash "$wslScriptDir/scripts/14-run-lambda-vm.sh" @fcArgs
exit $LASTEXITCODE
