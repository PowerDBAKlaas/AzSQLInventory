Import-Module PowerLine

# --- Timing state ---
$script:CmdStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:PrevSuccess  = $true
$script:PrevDuration = [timespan]::Zero

Set-PowerLinePrompt -PowerLineFont -Newline -SetCurrentDirectory `
    -Prompt @(
        # Block 0 — capture $? and duration BEFORE any other code runs
        {
            $script:PrevSuccess  = $?
            $script:CmdStopwatch.Stop()
            $script:PrevDuration = $script:CmdStopwatch.Elapsed
            $script:CmdStopwatch.Restart()
        },
        { " $(Split-Path $PWD -Leaf) " }
    ) `
    -Right @(
        {
            $ts  = Get-Date -Format 'HH:mm:ss'
            $dur = '{0:mm\:ss\.ff}' -f $script:PrevDuration
            $bg  = if ($script:PrevSuccess) { 'Green' } else { 'Red' }
            $fg  = if ($script:PrevSuccess) { 'Black' } else { 'White' }
            [PoshCode.Pansies.Text]@{ Bg = $bg; Fg = $fg; Object = " $ts  $dur " }
        }
    )
