<#
.SYNOPSIS
    Verify relocations: free space, junctions, environment variables, live writes.

.DESCRIPTION
    A junction that silently failed to be created and one that works look identical
    from the original path, so relocation is not finished until it has been checked.

    Without arguments, enumerates every junction under the current user's profile and
    common relocation roots, plus the relocation-related environment variables.

    With -Watch, confirms that an application is actually writing to the destination
    (the only check that proves the redirect is live rather than merely present).

.PARAMETER Path
    Specific path(s) to check instead of scanning.

.PARAMETER Watch
    Destination path to check for recent writes.

.PARAMETER WithinMinutes
    How recent a write must be to count under -Watch. Default 5.

.EXAMPLE
    .\Test-Migration.ps1
    Full report: volumes, junctions found, environment variables.

.EXAMPLE
    .\Test-Migration.ps1 -Watch 'D:\AppData\LarkShell'
    Start the app first, then run this to confirm writes land on D:.
#>
[CmdletBinding()]
param(
    [string[]] $Path,
    [string]   $Watch,
    [int]      $WithinMinutes = 5
)

$ErrorActionPreference = 'Continue'

function Test-Junction {
    param([string] $LiteralPath)

    $result = [PSCustomObject]@{
        Path    = $LiteralPath
        IsLink  = $false
        Target  = ''
        Healthy = $false
        Note    = ''
    }

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if (-not $item) { $result.Note = 'path does not exist'; return $result }

    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $result.Note = 'not a junction (still a real directory)'
        return $result
    }

    $result.IsLink = $true
    # .Target is a collection; joining avoids printing System.String[]
    $result.Target = ($item.Target -join ', ')

    if (-not $result.Target) {
        $result.Note = 'reparse point with no resolvable target - BROKEN'
        return $result
    }
    if (-not (Test-Path -LiteralPath $result.Target)) {
        $result.Note = 'target missing - BROKEN (is the drive connected?)'
        return $result
    }

    # A junction that resolves but whose target is empty usually means a failed move.
    $any = Get-ChildItem -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $any) {
        $result.Note = 'resolves but target is empty - verify the move completed'
        return $result
    }

    $result.Healthy = $true
    $result.Note    = 'OK'
    return $result
}

function Find-Junctions {
    param([string] $Root, [int] $MaxDepth = 3)

    $found = New-Object System.Collections.ArrayList
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push([PSCustomObject]@{ Dir = $Root; Depth = 0 })

    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        if ($cur.Depth -gt $MaxDepth) { continue }
        try {
            $di = New-Object System.IO.DirectoryInfo($cur.Dir)
            foreach ($d in $di.EnumerateDirectories()) {
                if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    [void]$found.Add($d.FullName)
                    continue   # never descend into a link
                }
                $stack.Push([PSCustomObject]@{ Dir = $d.FullName; Depth = $cur.Depth + 1 })
            }
        } catch { }
    }
    return $found
}

# --- Watch mode --------------------------------------------------------------

if ($Watch) {
    Write-Output ''
    Write-Output ('=== Recent writes under {0} (last {1} min) ===' -f $Watch, $WithinMinutes)

    if (-not (Test-Path -LiteralPath $Watch)) {
        Write-Output 'Destination does not exist.'
        exit 1
    }

    $cutoff = (Get-Date).AddMinutes(-$WithinMinutes)
    $recent = Get-ChildItem -LiteralPath $Watch -Recurse -Depth 2 -File -Force -ErrorAction SilentlyContinue |
              Where-Object { $_.LastWriteTime -gt $cutoff } |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 15

    if ($recent) {
        $recent | Format-Table @{ n = 'LastWrite'; e = { $_.LastWriteTime.ToString('HH:mm:ss') } },
                               @{ n = 'Name'; e = { $_.Name } } -AutoSize
        Write-Output 'CONFIRMED: the application is writing to the destination. Relocation is live.'
    } else {
        Write-Output 'No recent writes found.'
        Write-Output 'Start the relocated application, use it briefly, then run this again.'
        Write-Output 'If it still shows nothing, the app may be writing elsewhere - re-check the junction.'
    }
    exit 0
}

# --- Volumes -----------------------------------------------------------------

Write-Output ''
Write-Output '=== Volumes ==='
Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter | ForEach-Object {
    $pct = if ($_.Size -gt 0) { [math]::Round($_.SizeRemaining / $_.Size * 100, 1) } else { 0 }
    $flag = if ($pct -lt 10) { '  <-- LOW' } else { '' }
    '{0}:  {1,8:N1} GB free of {2,8:N1} GB  ({3,5:N1}%){4}' -f `
        $_.DriveLetter, ($_.SizeRemaining / 1GB), ($_.Size / 1GB), $pct, $flag
}

# --- Junctions ---------------------------------------------------------------

Write-Output ''
Write-Output '=== Junctions ==='

$targets = if ($Path) { $Path } else {
    $roots = @(
        "$env:APPDATA",
        "$env:LOCALAPPDATA",
        "$env:USERPROFILE\.claude",
        "$env:ProgramData"
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $all = New-Object System.Collections.ArrayList
    foreach ($r in $roots) {
        foreach ($j in (Find-Junctions -Root $r -MaxDepth 3)) { [void]$all.Add($j) }
    }
    $all
}

if (-not $targets -or $targets.Count -eq 0) {
    Write-Output 'No junctions found under the scanned roots.'
} else {
    $rows = foreach ($t in $targets) { Test-Junction -LiteralPath $t }
    $rows | Format-Table @{ n = 'OK'; e = { if ($_.Healthy) { 'yes' } else { 'NO' } }; w = 4 },
                         @{ n = 'Path'; e = { $_.Path } },
                         @{ n = 'Target'; e = { $_.Target } },
                         @{ n = 'Note'; e = { $_.Note } } -AutoSize

    $broken = @($rows | Where-Object { -not $_.Healthy })
    if ($broken.Count -gt 0) {
        Write-Output ('WARNING: {0} link(s) need attention - see the Note column.' -f $broken.Count)
    }
}

# --- Environment variables ---------------------------------------------------

Write-Output ''
Write-Output '=== Relocation environment variables (user scope) ==='

$vars = @(
    'NUGET_PACKAGES', 'PLAYWRIGHT_BROWSERS_PATH', 'PIP_CACHE_DIR', 'npm_config_cache',
    'CARGO_HOME', 'GRADLE_USER_HOME', 'GOPATH', 'GOMODCACHE',
    'UE-LocalDataCachePath', 'DOTNET_CLI_HOME', 'HF_HOME', 'TORCH_HOME'
)

$anySet = $false
foreach ($v in $vars) {
    $val = [Environment]::GetEnvironmentVariable($v, 'User')
    if ($val) {
        $anySet = $true
        $exists = if (Test-Path -LiteralPath $val) { 'OK' } else { 'MISSING PATH' }
        '{0,-26} = {1}   [{2}]' -f $v, $val, $exists
    }
}
if (-not $anySet) { Write-Output 'None set at user scope.' }

Write-Output ''
Write-Output 'Note: processes started before a variable was set still see the old value.'
Write-Output 'Restart IDEs and terminals before concluding a relocation did not work.'
Write-Output ''
Write-Output 'To prove a relocation is live, start the app and run:'
Write-Output '  .\Test-Migration.ps1 -Watch <destination path>'
