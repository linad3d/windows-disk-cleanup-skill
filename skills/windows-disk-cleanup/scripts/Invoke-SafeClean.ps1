<#
.SYNOPSIS
    Delete regenerable caches from an explicit allowlist. Dry-run by default.

.DESCRIPTION
    Only removes paths that match a hard-coded allowlist of known-regenerable cache
    locations. It cannot be pointed at an arbitrary directory, by design: the failure
    mode of a cleanup tool is deleting something irreplaceable, and an allowlist makes
    that structurally impossible rather than merely unlikely.

    Runs in dry-run mode unless -Execute is passed. Review the dry-run output with the
    user before executing.

    Deletion degrades gracefully: if a directory is partially locked it falls back to
    deepest-first per-file removal and reports what was actually freed, rather than
    failing the whole batch.

.PARAMETER Category
    Limit to one or more categories. Default: all.
    Valid: Temp, Browsers, Chromium, GPU, DevTools, Windows, Installers

.PARAMETER Execute
    Actually delete. Without it, nothing is removed.

.PARAMETER OlderThanDays
    For temp locations, only remove entries older than this. Default 7.

.EXAMPLE
    .\Invoke-SafeClean.ps1
    Dry run over every category - shows what would be freed.

.EXAMPLE
    .\Invoke-SafeClean.ps1 -Category GPU,DevTools -Execute
    Actually clear GPU and developer toolchain caches.

.NOTES
    Close the owning applications first. This script does not kill processes.
#>
[CmdletBinding()]
param(
    [ValidateSet('Temp', 'Browsers', 'Chromium', 'GPU', 'DevTools', 'Windows', 'Installers')]
    [string[]] $Category = @('Temp', 'Chromium', 'GPU', 'DevTools', 'Windows', 'Installers'),

    [switch] $Execute,

    [int] $OlderThanDays = 7
)

$ErrorActionPreference = 'Continue'
$script:TotalFreed = 0L
$script:Actions    = New-Object System.Collections.ArrayList

function Get-DirectorySize {
    param([string] $Root)
    $bytes = 0L
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo($dir)
            foreach ($fsi in $di.EnumerateFileSystemInfos()) {
                if ($fsi -is [System.IO.DirectoryInfo]) {
                    if ($fsi.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push($fsi.FullName)
                } else {
                    try { $bytes += $fsi.Length } catch { }
                }
            }
        } catch { }
    }
    return $bytes
}

function Get-ItemSize {
    param([string] $LiteralPath)
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if (-not $item) { return 0L }
    if ($item.PSIsContainer) { return (Get-DirectorySize $LiteralPath) }
    return $item.Length
}

function Remove-Safely {
    <#
        Removes a path, tolerating partially-locked directories.
        Returns the number of bytes actually freed.
    #>
    param([string] $LiteralPath)

    $before = Get-ItemSize $LiteralPath
    if ($before -eq 0 -and -not (Test-Path -LiteralPath $LiteralPath)) { return 0L }

    try {
        Remove-Item -LiteralPath $LiteralPath -Recurse -Force -ErrorAction Stop
        return $before
    } catch {
        # Partially locked. Delete deepest-first so directories are empty when removed.
        Get-ChildItem -LiteralPath $LiteralPath -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch { }
            }
        try { Remove-Item -LiteralPath $LiteralPath -Recurse -Force -ErrorAction Stop } catch { }

        $after = 0L
        if (Test-Path -LiteralPath $LiteralPath) { $after = Get-ItemSize $LiteralPath }
        return ($before - $after)
    }
}

function Add-Target {
    <# Record one candidate; delete it if -Execute. Always uses -LiteralPath because
       cache directories routinely contain [ ] and ` characters. #>
    param(
        [string] $LiteralPath,
        [string] $Label,
        [string] $Cat
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) { return }

    $size = Get-ItemSize $LiteralPath
    if ($size -le 0) { return }

    if ($Execute) {
        $freed = Remove-Safely $LiteralPath
        $script:TotalFreed += $freed
        $status = if ($freed -ge $size) { 'DELETED' } else { 'PARTIAL' }
        [void]$script:Actions.Add([PSCustomObject]@{
            Status = $status; MB = [math]::Round($freed / 1MB, 1); Category = $Cat; Item = $Label
        })
    } else {
        $script:TotalFreed += $size
        [void]$script:Actions.Add([PSCustomObject]@{
            Status = 'WOULD-DELETE'; MB = [math]::Round($size / 1MB, 1); Category = $Cat; Item = $Label
        })
    }
}

function Add-AgedChildren {
    <# For temp dirs: only entries older than -OlderThanDays, and never the Keep list. #>
    param(
        [string] $Root,
        [string] $Cat,
        [string[]] $Keep = @()
    )
    if (-not (Test-Path -LiteralPath $Root)) { return }
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)

    Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $Keep -and $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { Add-Target -LiteralPath $_.FullName -Label ("{0}\{1}" -f (Split-Path $Root -Leaf), $_.Name) -Cat $Cat }
}

function Add-ChromiumCaches {
    <#
        Recursively finds regenerable cache directories inside a Chromium-style
        profile tree.

        Deliberately NOT deleted: IndexedDB, Local Storage, Session Storage, Cookies,
        Login Data, and Service Worker\Database - those hold login state and app data.
        Note CacheStorage is only taken when its parent is 'Service Worker'.
    #>
    param([string] $Root, [string] $Label, [string] $Cat)

    if (-not (Test-Path -LiteralPath $Root)) { return }

    $cacheNames = @(
        'Cache_Data', 'Code Cache', 'GPUCache', 'ShaderCache',
        'GrShaderCache', 'DawnCache', 'GraphiteDawnCache', 'CodeCache'
    )

    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Root)
    $found = New-Object System.Collections.ArrayList

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) {
                $name = [System.IO.Path]::GetFileName($d)
                if ($cacheNames -contains $name) { [void]$found.Add($d); continue }
                if ($name -eq 'CacheStorage' -and
                    [System.IO.Path]::GetFileName($dir) -eq 'Service Worker') {
                    [void]$found.Add($d); continue
                }
                $stack.Push($d)
            }
        } catch { }
    }

    foreach ($f in $found) {
        Add-Target -LiteralPath $f -Label ("{0}: {1}" -f $Label, $f.Replace($Root, '').TrimStart('\')) -Cat $Cat
    }
}

# ---------------------------------------------------------------------------
# Allowlist
# ---------------------------------------------------------------------------

if ($Category -contains 'Temp') {
    Add-AgedChildren -Root "$env:LOCALAPPDATA\Temp" -Cat 'Temp' -Keep @('claude')
    Add-AgedChildren -Root "$env:SystemRoot\Temp"   -Cat 'Temp'
}

if ($Category -contains 'Installers') {
    Add-Target -LiteralPath "$env:SystemRoot\SoftwareDistribution\Download" -Label 'Windows Update payloads' -Cat 'Installers'
    Add-Target -LiteralPath "$env:LOCALAPPDATA\electron\Cache"              -Label 'Electron download cache' -Cat 'Installers'
    Add-Target -LiteralPath "$env:LOCALAPPDATA\electron-builder\Cache"      -Label 'electron-builder cache'  -Cat 'Installers'
    Add-Target -LiteralPath "$env:USERPROFILE\scoop\cache"                  -Label 'Scoop package cache'     -Cat 'Installers'
}

if ($Category -contains 'GPU') {
    Add-Target -LiteralPath "$env:LOCALAPPDATA\NVIDIA\DXCache"                 -Label 'NVIDIA DirectX shader cache' -Cat 'GPU'
    Add-Target -LiteralPath "$env:LOCALAPPDATA\NVIDIA Corporation\NV_Cache"    -Label 'NVIDIA GL/VK shader cache'    -Cat 'GPU'
    Add-Target -LiteralPath "$env:LOCALAPPDATA\AMD\DxCache"                    -Label 'AMD DirectX shader cache'     -Cat 'GPU'
    Add-Target -LiteralPath "$env:LOCALAPPDATA\D3DSCache"                      -Label 'Direct3D shader cache'        -Cat 'GPU'
    # Driver installer payloads - requires elevation. Installed drivers unaffected.
    Add-Target -LiteralPath "$env:ProgramData\NVIDIA Corporation\Downloader"   -Label 'NVIDIA driver downloads'      -Cat 'GPU'
    Add-Target -LiteralPath "$env:ProgramData\NVIDIA Corporation\NVIDIA app\UpdateFramework\ota-artifacts" -Label 'NVIDIA OTA artifacts' -Cat 'GPU'
}

if ($Category -contains 'DevTools') {
    Add-Target -LiteralPath "$env:LOCALAPPDATA\pip\Cache"        -Label 'pip cache'         -Cat 'DevTools'
    Add-Target -LiteralPath "$env:APPDATA\npm-cache"             -Label 'npm cache'         -Cat 'DevTools'
    Add-Target -LiteralPath "$env:LOCALAPPDATA\Yarn\Cache"       -Label 'Yarn cache'        -Cat 'DevTools'
    Add-Target -LiteralPath "$env:USERPROFILE\.cargo\registry\cache" -Label 'Cargo registry cache' -Cat 'DevTools'
    Add-Target -LiteralPath "$env:USERPROFILE\.gradle\caches\build-cache-1" -Label 'Gradle build cache' -Cat 'DevTools'
    Add-Target -LiteralPath "$env:LOCALAPPDATA\NuGet\v3-cache"   -Label 'NuGet http cache'  -Cat 'DevTools'
    # Unreal: DDC regenerates from .uasset. Abandoned Zen backups are pure waste.
    Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\UnrealEngine\Common\Zen" -Directory -Filter 'Data.bak-*' -ErrorAction SilentlyContinue |
        ForEach-Object { Add-Target -LiteralPath $_.FullName -Label ('UE Zen abandoned backup: ' + $_.Name) -Cat 'DevTools' }
    Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\EpicGamesLauncher\Saved" -Directory -Filter 'webcache*' -ErrorAction SilentlyContinue |
        ForEach-Object { Add-Target -LiteralPath $_.FullName -Label ('Epic launcher web cache: ' + $_.Name) -Cat 'DevTools' }
}

if ($Category -contains 'Windows') {
    Add-Target -LiteralPath "$env:LOCALAPPDATA\CrashDumps"          -Label 'Crash dumps'            -Cat 'Windows'
    Add-Target -LiteralPath "$env:SystemRoot\LiveKernelReports"     -Label 'Live kernel reports'    -Cat 'Windows'
    Add-Target -LiteralPath "$env:SystemRoot\Logs\CBS"              -Label 'CBS servicing logs'     -Cat 'Windows'
    Add-Target -LiteralPath "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_idx.db" -Label 'Thumbnail cache index' -Cat 'Windows'
    Add-Target -LiteralPath "$env:LOCALAPPDATA\Microsoft\Windows\WebCache" -Label 'WinINET web cache' -Cat 'Windows'
}

if ($Category -contains 'Chromium') {
    # Electron/CEF desktop apps. Browsers are intentionally excluded here - see the
    # Browsers category and the atlas: the payoff is small and the downside is a
    # corrupted profile.
    Add-ChromiumCaches -Root "$env:APPDATA\LarkShell"      -Label 'Feishu/Lark' -Cat 'Chromium'
    Add-ChromiumCaches -Root "$env:APPDATA\Slack"          -Label 'Slack'       -Cat 'Chromium'
    Add-ChromiumCaches -Root "$env:APPDATA\discord"        -Label 'Discord'     -Cat 'Chromium'
    Add-ChromiumCaches -Root "$env:APPDATA\Microsoft\Teams" -Label 'Teams'      -Cat 'Chromium'

    # Feishu SDK logs: clear contents, keep the directory itself.
    $larkLog = "$env:APPDATA\LarkShell\sdk_storage\log"
    if (Test-Path -LiteralPath $larkLog) {
        Get-ChildItem -LiteralPath $larkLog -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Add-Target -LiteralPath $_.FullName -Label ('Feishu/Lark SDK log: ' + $_.Name) -Cat 'Chromium' }
    }
}

if ($Category -contains 'Browsers') {
    Write-Warning 'Browser profiles are excluded by design. A full disk is exactly when browsers corrupt their databases; the safe move is to free space elsewhere and restart the browser. Use the browser UI if you really want to clear its cache.'
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

Write-Output ''
if ($script:Actions.Count -eq 0) {
    Write-Output 'Nothing found in the selected categories.'
} else {
    $script:Actions |
        Sort-Object MB -Descending |
        Format-Table @{ n = 'Status'; e = { $_.Status }; w = 14 },
                     @{ n = 'MB'; e = { '{0,10:N1}' -f $_.MB } },
                     @{ n = 'Category'; e = { $_.Category }; w = 10 },
                     @{ n = 'Item'; e = { $_.Item } } -AutoSize
}

Write-Output ''
if ($Execute) {
    Write-Output ('Freed: {0:N2} GB' -f ($script:TotalFreed / 1GB))
    Write-Output 'Re-run Scan-DiskUsage.ps1 to confirm.'
} else {
    Write-Output ('DRY RUN - would free approximately {0:N2} GB' -f ($script:TotalFreed / 1GB))
    Write-Output 'Nothing was deleted. Review the list above, then re-run with -Execute.'
}
Write-Output 'Items too valuable to delete should be relocated instead - see Move-AppData.ps1'
