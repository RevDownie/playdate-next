# Launch the game in the Playdate Simulator, capture its output and screenshot the window.
#   powershell -File tools/sim.ps1 [-Seconds 8] [-NoBuild] [-Invincible] [-Level <name>]
# Outputs (git-ignored) in logs/: sim-stdout.log, sim-stderr.log, screenshot.png
param(
    [int]$Seconds = 8,
    [switch]$NoBuild,
    [switch]$Invincible, # Debug build where enemies can't hurt the player (also a system menu checkmark)
    [string]$Level = "" # Debug build that only plays this level (LEVEL_NAMES in main.zig; also a system menu option)
)

. "$PSScriptRoot\sim-common.ps1"

$root = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $root "logs"
New-Item -ItemType Directory -Force $logs | Out-Null
$out = Join-Path $logs "sim-stdout.log"
$err = Join-Path $logs "sim-stderr.log"
$shot = Join-Path $logs "screenshot.png"
Remove-Item $out, $err, $shot -ErrorAction SilentlyContinue

# A running simulator locks pdex.dll, so stop it before building
Get-Process PlaydateSimulator -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

if (-not $NoBuild) {
    Push-Location $root
    $buildArgs = @("build")
    if ($Invincible) { $buildArgs += "-Dinvincible=true" }
    if ($Level) { $buildArgs += "-Dlevel=$Level" }
    zig @buildArgs 2>&1 | Where-Object { $_ -notmatch '^\s*[+|]|^Copying|^Unrecognized' }
    $buildOk = $LASTEXITCODE -eq 0
    Pop-Location
    if (-not $buildOk) { Write-Output "BUILD FAILED"; exit 1 }
}


$sim = Join-Path $env:PLAYDATE_SDK_PATH "bin\PlaydateSimulator.exe"
$p = Start-Process -FilePath $sim -ArgumentList (Join-Path $root "zig-out\until-none.pdx") `
    -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
Start-Sleep -Seconds $Seconds

if ($p.HasExited) {
    Write-Output "SIMULATOR EXITED (code $($p.ExitCode)) - game likely crashed, see stderr below"
} else {
    try {
        Save-SimScreenshot $shot
        Write-Output "Screenshot: $shot"
    } catch {
        Write-Output "Screenshot failed: $_"
    }
    Write-Output "Simulator still running (pid $($p.Id)); stop with: Stop-Process -Name PlaydateSimulator"
}

foreach ($f in $out, $err) {
    Write-Output "--- $(Split-Path -Leaf $f)"
    Get-Content $f -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\[sentry\]' } | Select-Object -First 40
}

# Debug builds append to log.txt in the game's simulator data folder (see debugLog in src/main.zig)
$gamelog = Join-Path $env:PLAYDATE_SDK_PATH "Disk\Data\com.downie.next\log.txt"
Write-Output "--- game log.txt (last 20 lines): $gamelog"
Get-Content $gamelog -Tail 20 -ErrorAction SilentlyContinue
