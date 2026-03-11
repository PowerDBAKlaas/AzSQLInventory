function prompt {
    try {
        if ($null -eq $script:sw) {
            $script:sw           = [System.Diagnostics.Stopwatch]::StartNew()
            $script:lastSuccess  = $true
            $script:lastDuration = [timespan]::Zero
        }

        $script:lastSuccess  = $?
        $script:sw.Stop()
        $script:lastDuration = $script:sw.Elapsed
        $script:sw.Restart()

        $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $dur   = '{0:mm\:ss\.fff}' -f $script:lastDuration
        $clock = "`u{F017}"
        $color = if ($script:lastSuccess) { "`e[42;30m" } else { "`e[41;37m" }
        $reset = "`e[0m"

        $rightBlock = "${color} ${ts} `e[37;40m${clock}${color} ${dur} ${reset}"
        $plainLen   = " $ts  $dur ".Length + 1
        $width      = $Host.UI.RawUI.WindowSize.Width
        $pos        = $Host.UI.RawUI.CursorPosition
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new($width - $plainLen, $pos.Y)
        Write-Host $rightBlock -NoNewline

        $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                        [Security.Principal.WindowsBuiltInRole]::Administrator)

        $psIcon  = "`u{E7A2}"
        $ver     = "`e[2m${psIcon} $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)`e[0m"
        $path    = "`e[2m$($PWD.Drive.Name):\$(Split-Path $PWD -Leaf)`e[0m"
        $chevron = if ($isElevated) { "`e[33m`u{F0E7}`e[0m" } else { "`e[32m>`e[0m" }

        "`n$ver $path $chevron "
    }
    catch {
        Write-Host "`e[31mPrompt error: $_`e[0m" -NoNewline
        "`nPS $($PWD)> "
    }
}
