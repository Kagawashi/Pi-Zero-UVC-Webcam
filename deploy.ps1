<#
.SYNOPSIS
    Automated deployment script for Raspberry Pi Zero UVC Camera gadget to target Pi.

.DESCRIPTION
    Syncs the repository files to the target Raspberry Pi over SSH/SCP,
    executes the installer or quick updater, configures persistent role/sensor settings,
    and verifies UVC gadget and streaming service activation.

.PARAMETER TargetHost
    Hostname or IP of the target Raspberry Pi (default: pizero.local).

.PARAMETER User
    Remote username (default: pi).

.PARAMETER Role
    UVC camera role: eye0, eye1, world, or generic (default: eye0).

.PARAMETER Sensor
    Camera sensor type: ov5647, imx219, or ov9281 (default: ov5647).

.PARAMETER Port
    SSH/SCP port (1-65535, default: 22).

.PARAMETER KeyPath
    Path to custom private SSH key (optional).

.PARAMETER RemoteDest
    Remote destination directory on the Pi (default: ~/pi-zero-uvc-cam/).

.PARAMETER SkipInstall
    Quick mode: updates scripts, units, and configuration without re-compiling uvc-gadget (aliased as -Quick).

.PARAMETER DryRun
    Previews constructed SSH/SCP commands and setup script without executing network calls.
#>

[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [string]$TargetHost = "pizero.local",

    [Parameter(Position = 1)]
    [string]$User = "pi",

    [Parameter(Position = 2)]
    [ValidateSet("eye0", "eye1", "world", "generic")]
    [string]$Role = "eye0",

    [Parameter(Position = 3)]
    [ValidateSet("ov5647", "imx219", "ov9281")]
    [string]$Sensor = "ov5647",

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$Port = 22,

    [Parameter()]
    [string]$KeyPath = "",

    [Parameter()]
    [string]$RemoteDest = "~/pi-zero-uvc-cam/",

    [Parameter()]
    [Alias("Quick")]
    [switch]$SkipInstall,

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Input Validation
if ([string]::IsNullOrWhiteSpace($TargetHost)) {
    throw "TargetHost cannot be empty"
}
if ([string]::IsNullOrWhiteSpace($User)) {
    throw "User cannot be empty"
}
if ([string]::IsNullOrWhiteSpace($RemoteDest)) {
    throw "RemoteDest cannot be empty"
}

# Check OpenSSH client tools when not in dry-run mode
if (-not $DryRun) {
    if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue) -or -not (Get-Command scp.exe -ErrorAction SilentlyContinue)) {
        throw "OpenSSH Client (ssh.exe / scp.exe) is not found in PATH. Please install OpenSSH Client via Windows Optional Features."
    }
}

# Validate KeyPath if provided
if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
    if (-not (Test-Path -Path $KeyPath -PathType Leaf)) {
        throw "SSH private key file not found: '$KeyPath'"
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Raspberry Pi Zero UVC Gadget - Automated Deployment (PowerShell)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Target Host : $User@$TargetHost"
Write-Host "Port        : $Port"
Write-Host "Role        : $Role"
Write-Host "Sensor      : $Sensor"
Write-Host "Remote Dest : $RemoteDest"
Write-Host "Quick Mode  : $([bool]$SkipInstall)"
Write-Host "Dry Run     : $([bool]$DryRun)"
Write-Host "----------------------------------------------------------"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# Build SCP arguments with explicit payload items
$PayloadNames = @("scripts", "services", "uvc-gadget", "web", "install.sh")
$PayloadItems = @()
foreach ($item in $PayloadNames) {
    $fullPath = Join-Path $ScriptDir $item
    if (-not (Test-Path -Path $fullPath)) {
        throw "Required payload item '$item' not found in $ScriptDir"
    }
    $PayloadItems += $fullPath
}
$KernelDir = Join-Path $ScriptDir "kernel"
if (Test-Path -Path $KernelDir) {
    $PayloadItems += $KernelDir
}

# Clean local uvc-gadget/build if present to prevent transferring host x86 build artifacts
$HostBuildDir = Join-Path $ScriptDir "uvc-gadget\build"
if (Test-Path -Path $HostBuildDir) {
    Write-Host "Cleaning host build directory before deployment: $HostBuildDir" -ForegroundColor DarkGray
    Remove-Item -Recurse -Force $HostBuildDir -ErrorAction SilentlyContinue
}

$ScpArgs = @("-r")
if ($Port -ne 22) {
    $ScpArgs += @("-P", "$Port")
}
if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
    $ScpArgs += @("-i", "$KeyPath")
}
# Destination string
$RemoteDestTarget = "$($User)@$($TargetHost):$RemoteDest"
$ScpArgs += $PayloadItems + @($RemoteDestTarget)

# SSH base arguments
$SshBaseArgs = @()
if ($Port -ne 22) {
    $SshBaseArgs += @("-p", "$Port")
}
if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
    $SshBaseArgs += @("-i", "$KeyPath")
}

# Helper to execute native commands safely on PS 5.1 avoiding NativeCommandError
function Invoke-SafeNative {
    param (
        [string]$CommandName,
        [string[]]$Arguments,
        [string]$StepDescription
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $CommandName @Arguments
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-Host "`n[!] ERROR: $StepDescription failed with exit code $exitCode" -ForegroundColor Red
            Write-Host "Troubleshooting Guidance:" -ForegroundColor Yellow
            Write-Host "  1. Verify the Raspberry Pi Zero is powered on and connected to the network."
            Write-Host "  2. Test SSH connectivity manually: ssh $(if ($Port -ne 22) { "-p $Port " })$($User)@$($TargetHost)"
            Write-Host "  3. If using mDNS ('$TargetHost'), verify your host can resolve it or try using direct IP."
            Write-Host "  4. Check authentication / credentials or SSH key path: '$KeyPath'"
            Write-Host "  5. View remote service logs: ssh $($User)@$($TargetHost) 'sudo journalctl -u uvc-gadget -n 50'"
            throw "$StepDescription failed with exit code $exitCode"
        }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# Remote Setup Command Construction
# We write/update /etc/default/picam-uvc with ROLE and SENSOR
$ConfigUpdateCmd = "sudo mkdir -p /etc/default && " +
    "sudo sh -c 'if [ ! -f /etc/default/picam-uvc ]; then " +
    "printf ""ROLE=\""$Role\""\nSENSOR=\""$Sensor\""\nFPS=\""90\""\nWIDTH=\""640\""\nHEIGHT=\""480\""\nALLOW_TEST_PATTERN=\""true\""\n"" > /etc/default/picam-uvc; " +
    "else " +
    "grep -q ""^ROLE="" /etc/default/picam-uvc && sed -i ""s/^ROLE=.*/ROLE=\""$Role\""/"" /etc/default/picam-uvc || echo ""ROLE=\""$Role\"""" >> /etc/default/picam-uvc; " +
    "grep -q ""^SENSOR="" /etc/default/picam-uvc && sed -i ""s/^SENSOR=.*/SENSOR=\""$Sensor\""/"" /etc/default/picam-uvc || echo ""SENSOR=\""$Sensor\"""" >> /etc/default/picam-uvc; " +
    "grep -q ""^ALLOW_TEST_PATTERN="" /etc/default/picam-uvc && sed -i ""s/^ALLOW_TEST_PATTERN=.*/ALLOW_TEST_PATTERN=\""true\""/"" /etc/default/picam-uvc || echo ""ALLOW_TEST_PATTERN=\""true\"""" >> /etc/default/picam-uvc; " +
    "fi; chmod 644 /etc/default/picam-uvc'"

if ($SkipInstall) {
    $RemoteSetupCmd = "cd ""$RemoteDest"" && " +
        "sudo install -m 755 scripts/setup-gadget.sh /usr/local/bin/setup-gadget.sh && " +
        "sudo install -m 755 scripts/start-uvc.sh /usr/local/bin/start-uvc.sh && " +
        "( [ ! -f scripts/build-ov5647-driver.sh ] || sudo install -m 755 scripts/build-ov5647-driver.sh /usr/local/bin/build-ov5647-driver.sh ) && " +
        "( [ ! -d web ] || ( sudo cp -r web/*.py /opt/picam-web/ 2>/dev/null || true; sudo cp -r web/templates /opt/picam-web/ 2>/dev/null || true ) ) && " +
        "sudo install -m 644 services/uvc-gadget.service /etc/systemd/system/uvc-gadget.service && " +
        "sudo install -m 644 services/picam-web.service /etc/systemd/system/picam-web.service && " +
        "sudo systemctl daemon-reload && " +
        "sudo systemctl restart picam-web && " +
        "$ConfigUpdateCmd && " +
        "sudo systemctl stop uvc-gadget 2>/dev/null; " +
        "sudo /usr/local/bin/setup-gadget.sh '$Role' restart && " +
        "sudo systemctl restart uvc-gadget"
} else {
    $RemoteSetupCmd = "cd ""$RemoteDest"" && " +
        "sudo bash install.sh && " +
        "$ConfigUpdateCmd && " +
        "sudo /usr/local/bin/setup-gadget.sh $Role restart && " +
        "sudo systemctl restart uvc-gadget"
}

# Expected product descriptor string per role
$ExpectedProduct = switch ($Role) {
    "eye0"    { "Pupil Cam1 ID0" }
    "eye1"    { "Pupil Cam1 ID1" }
    "world"   { "Pupil Cam1 ID2" }
    "generic" { "Pi Zero UVC Camera" }
}

$VerifyCmd = "systemctl is-active uvc-gadget >/dev/null 2>&1 && " +
    "test -f /sys/kernel/config/usb_gadget/pi_uvc/strings/0x409/product && " +
    "test -s /sys/kernel/config/usb_gadget/pi_uvc/UDC && " +
    "cat /sys/kernel/config/usb_gadget/pi_uvc/strings/0x409/product"

$MkdirArgs = $SshBaseArgs + @("$($User)@$($TargetHost)", "mkdir -p ""$RemoteDest""")
$RemoteSetupArgs = $SshBaseArgs + @("$($User)@$($TargetHost)", $RemoteSetupCmd)
$VerifyArgs = $SshBaseArgs + @("$($User)@$($TargetHost)", $VerifyCmd)

if ($DryRun) {
    Write-Host "[DRY RUN] Command preview:" -ForegroundColor Yellow
    Write-Host "1. Create Remote Destination:"
    Write-Host "   ssh $($MkdirArgs -join ' ')"
    Write-Host "2. Sync Payload (SCP):"
    Write-Host "   scp $($ScpArgs -join ' ')"
    Write-Host "3. Remote Setup & Service Restart:"
    Write-Host "   ssh $($RemoteSetupArgs -join ' ')"
    Write-Host "4. Remote Verification:"
    Write-Host "   ssh $($VerifyArgs -join ' ')"
    Write-Host "   Expected product: '$ExpectedProduct'"
    Write-Host "`n[DRY RUN] Completed successfully without network operations." -ForegroundColor Green
    exit 0
}

# Step 1: Ensure remote destination exists and sync payload
Write-Host "[1/3] Preparing remote destination directory and syncing files..." -ForegroundColor Yellow
Invoke-SafeNative "ssh" $MkdirArgs "Remote directory creation"

Invoke-SafeNative "scp" $ScpArgs "SCP file synchronization"
Write-Host "  -> Sync complete." -ForegroundColor Green

# Step 2: Execute remote setup
Write-Host "[2/3] Executing remote setup and service activation..." -ForegroundColor Yellow
Invoke-SafeNative "ssh" $RemoteSetupArgs "Remote gadget setup"
Write-Host "  -> Gadget configured, persistence saved, and service restarted." -ForegroundColor Green

# Step 3: Remote verification
Write-Host "[3/3] Verifying remote UVC service status and USB gadget identity..." -ForegroundColor Yellow
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $Output = & ssh @VerifyArgs
    $verifyExit = $LASTEXITCODE
    if ($verifyExit -ne 0) {
        Write-Host "`n[!] Remote verification check failed (exit code $verifyExit)!" -ForegroundColor Red
        Write-Host "Troubleshooting:" -ForegroundColor Yellow
        Write-Host "  1. Check systemctl status: ssh $($User)@$($TargetHost) 'systemctl status uvc-gadget --no-pager'"
        Write-Host "  2. If fresh install, a reboot may be needed to activate dwc2 USB Device Controller (/sys/class/udc)."
        throw "Remote verification failed with exit code $verifyExit"
    }
    $productOutput = ($Output | Out-String).Trim()
    if ($productOutput -ne $ExpectedProduct) {
        throw "Product string mismatch: expected '$ExpectedProduct', but target reported '$productOutput'"
    }
    Write-Host "  -> Verification passed: service active, UDC bound, product='$productOutput'" -ForegroundColor Green
} finally {
    $ErrorActionPreference = $prevEAP
}

Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  Deployment Successful!" -ForegroundColor Green
Write-Host "  Device is ready in role: $Role ($ExpectedProduct), sensor: $Sensor" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
