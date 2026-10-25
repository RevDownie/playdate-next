# Shared helpers for driving the Playdate Simulator window. Dot-source from other scripts:  . "$PSScriptRoot\sim-common.ps1"
# Input is posted straight to the simulator window (PostMessage), so it works while the window is in the background.

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SimWin {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
[SimWin]::SetProcessDPIAware() | Out-Null

$script:SimLogsDir = Join-Path (Split-Path -Parent $PSScriptRoot) "logs"
$script:GameLog = Join-Path $env:PLAYDATE_SDK_PATH "Disk\Data\com.downie.next\log.txt"

# Simulator keyboard bindings (the on-screen "B" button is the A key, the on-screen "A" button is the S key)
$script:KeyCodes = @{
    left = 0x25; up = 0x26; right = 0x27; down = 0x28
    b = 0x41   # 'A' key
    a = 0x53   # 'S' key
}

# Degrees of crank rotation per mouse wheel notch (calibrated against getCrankAngle in the game log)
$script:CrankDegreesPerNotch = 4

function Get-SimWindow {
    $p = Get-Process PlaydateSimulator -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { throw "Playdate Simulator is not running" }
    return $p.MainWindowHandle
}

function Save-SimScreenshot([string]$Path) {
    $h = Get-SimWindow
    $r = New-Object SimWin+RECT
    [SimWin]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $dc = $g.GetHdc()
    [SimWin]::PrintWindow($h, $dc, 2) | Out-Null   # 2 = PW_RENDERFULLCONTENT
    $g.ReleaseHdc($dc)
    $bmp.Save($Path)
    $g.Dispose(); $bmp.Dispose()
}

function Send-SimKey([string]$Button, [int]$HoldMs) {
    $vk = $script:KeyCodes[$Button.ToLower()]
    if (-not $vk) { throw "Unknown button '$Button' (use up/down/left/right/a/b)" }
    $h = Get-SimWindow
    $sc = [SimWin]::MapVirtualKey($vk, 0)
    # Arrow keys are "extended" keys; SDL needs bit 24 set to map them to the right scancode
    $ext = if ($vk -ge 0x25 -and $vk -le 0x28) { 1 -shl 24 } else { 0 }
    $down = [IntPtr](1 -bor ($sc -shl 16) -bor $ext)
    $up = [IntPtr](1 -bor ($sc -shl 16) -bor $ext -bor (1 -shl 30) -bor (1 -shl 31))
    [SimWin]::PostMessage($h, 0x100, [IntPtr]$vk, $down) | Out-Null   # WM_KEYDOWN
    Start-Sleep -Milliseconds $HoldMs
    [SimWin]::PostMessage($h, 0x101, [IntPtr]$vk, $up) | Out-Null     # WM_KEYUP
}

# Positive degrees = crank forward (angle increases). Posted as mouse wheel notches over the device screen.
function Send-SimCrank([double]$Degrees) {
    $h = Get-SimWindow
    $r = New-Object SimWin+RECT
    [SimWin]::GetWindowRect($h, [ref]$r) | Out-Null
    $x = $r.L + 400; $y = $r.T + 300
    $lp = [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))
    $notches = [int][Math]::Round([Math]::Abs($Degrees) / $script:CrankDegreesPerNotch)
    $delta = if ($Degrees -ge 0) { 120 } else { -120 }
    $wp = [IntPtr](($delta -shl 16) -band 0xFFFFFFFF)
    for ($i = 0; $i -lt $notches; $i++) {
        [SimWin]::PostMessage($h, 0x20A, $wp, $lp) | Out-Null   # WM_MOUSEWHEEL
        Start-Sleep -Milliseconds 40
    }
}
