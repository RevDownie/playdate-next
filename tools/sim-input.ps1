# Drive a running Playdate Simulator with button / D-pad / crank input, then inspect the result.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/sim-input.ps1 -Steps "down:200,wait:300,a:200,wait:1000,right:1500,a:600,crank:180,wait:500,shot,log"
#
# Steps (comma separated, run in order):
#   up|down|left|right|a|b[:ms]   hold that button for ms (default 300)
#   crank:<degrees>               turn the crank; positive = forward/clockwise, negative = backwards
#   wait:<ms>                     do nothing
#   shot[:name]                   screenshot to logs/<name>.png (default logs/screenshot.png)
#   log[:lines]                   print the last N lines of the game's log.txt (default 5)
# Start the game first with tools/sim.ps1 (use -NoBuild to skip rebuilding).
param(
    [Parameter(Mandatory = $true)][string]$Steps
)

. "$PSScriptRoot\sim-common.ps1"

foreach ($step in ($Steps -split ',')) {
    $name, $arg = ($step.Trim() -split ':', 2)
    switch -Regex ($name.ToLower()) {
        '^(up|down|left|right|a|b)$' {
            $ms = if ($arg) { [int]$arg } else { 300 }
            Write-Output "press $name for ${ms}ms"
            Send-SimKey $name $ms
        }
        '^crank$' {
            Write-Output "crank $arg degrees"
            Send-SimCrank ([double]$arg)
        }
        '^wait$' { Start-Sleep -Milliseconds ([int]$arg) }
        '^shot$' {
            $file = Join-Path $script:SimLogsDir ($(if ($arg) { $arg } else { "screenshot" }) + ".png")
            Save-SimScreenshot $file
            Write-Output "screenshot: $file"
        }
        '^log$' {
            $n = if ($arg) { [int]$arg } else { 5 }
            Get-Content $script:GameLog -Tail $n -ErrorAction SilentlyContinue
        }
        default { throw "Unknown step '$step'" }
    }
}
