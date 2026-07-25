<#
.SYNOPSIS
    Report which directories are actually consuming disk space.

.DESCRIPTION
    Walks a directory tree with an explicit stack over .NET EnumerateFileSystemInfos.

    Why not Get-ChildItem -Recurse:
      - it follows reparse points, so a relocated folder is counted twice (or recursed
        into forever)
      - it aborts on access-denied subtrees
      - it is markedly slower on large trees

    This function skips reparse points, swallows per-directory access errors, and is
    iterative so deep trees cannot exhaust the call stack.

.PARAMETER Path
    Root to scan. Defaults to the system drive.

.PARAMETER MinGB
    Only report entries at or above this size. Default 0.3 GB.

.PARAMETER Depth
    How many levels below Path to report. Default 1 (immediate children).

.PARAMETER Top
    Report only the N largest entries.

.EXAMPLE
    .\Scan-DiskUsage.ps1
    Show volumes plus the big folders directly under C:\

.EXAMPLE
    .\Scan-DiskUsage.ps1 -Path $env:LOCALAPPDATA -MinGB 0.1 -Depth 2
    Drill into AppData\Local two levels down.
#>
[CmdletBinding()]
param(
    [string] $Path   = $env:SystemDrive + '\',
    [double] $MinGB  = 0.3,
    [int]    $Depth  = 1,
    [int]    $Top    = 0
)

$ErrorActionPreference = 'Continue'

function Get-DirectorySize {
    <# Returns [PSCustomObject] with Bytes and Files. Skips reparse points. #>
    param([string] $Root)

    $bytes = 0L
    $files = 0L
    # The generic type name must be quoted, otherwise PowerShell parses the brackets
    # as an index expression and silently hands back $null.
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
                    try { $bytes += $fsi.Length; $files++ } catch { }
                }
            }
        } catch {
            # Unreadable subtree (ACL, in-use, transient). Skip it rather than
            # aborting the entire scan - a partial number beats no number.
        }
    }

    return [PSCustomObject]@{ Bytes = $bytes; Files = $files }
}

function Show-Volumes {
    Write-Output ''
    Write-Output '=== Volumes ==='
    Get-Volume |
        Where-Object { $_.DriveLetter } |
        Sort-Object DriveLetter |
        ForEach-Object {
            $pct = if ($_.Size -gt 0) { [math]::Round($_.SizeRemaining / $_.Size * 100, 1) } else { 0 }
            $flag = if ($pct -lt 10) { '  <-- LOW' } else { '' }
            '{0}:  {1,8:N1} GB total  {2,8:N1} GB free  ({3,5:N1}%){4}' -f `
                $_.DriveLetter,
                ($_.Size / 1GB),
                ($_.SizeRemaining / 1GB),
                $pct,
                $flag
        }
}

function Invoke-Scan {
    param([string] $Root, [int] $Level)

    if ($Level -gt $Depth) { return }

    $results = New-Object System.Collections.ArrayList

    Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            # Do not descend into reparse points, and skip system pseudo-directories
            -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
            $_.Name -notin @('$Recycle.Bin', 'System Volume Information')
        } |
        ForEach-Object {
            $size = Get-DirectorySize $_.FullName
            $gb   = $size.Bytes / 1GB
            if ($gb -ge $MinGB) {
                [void]$results.Add([PSCustomObject]@{
                    GB    = [math]::Round($gb, 2)
                    Files = $size.Files
                    Path  = $_.FullName
                    Full  = $_.FullName
                })
            }
        }

    # Large loose files matter too - pagefile, VHDX, ISO downloads.
    Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue |
        Where-Object { ($_.Length / 1GB) -ge $MinGB } |
        ForEach-Object {
            [void]$results.Add([PSCustomObject]@{
                GB    = [math]::Round($_.Length / 1GB, 2)
                Files = 1
                Path  = $_.FullName + '  [file]'
                Full  = $_.FullName
            })
        }

    $sorted = $results | Sort-Object GB -Descending
    if ($Top -gt 0) { $sorted = $sorted | Select-Object -First $Top }

    foreach ($r in $sorted) {
        '{0,8:N2} GB  {1,9:N0} files  {2}' -f $r.GB, $r.Files, $r.Path
        if ($Level -lt $Depth) {
            $child = Get-Item -LiteralPath $r.Full -Force -ErrorAction SilentlyContinue
            if ($child -and $child.PSIsContainer) {
                Invoke-Scan -Root $r.Full -Level ($Level + 1)
            }
        }
    }
}

Show-Volumes

Write-Output ''
Write-Output ("=== Directories under {0} at or above {1} GB ===" -f $Path, $MinGB)
Write-Output ''
Invoke-Scan -Root $Path -Level 1

Write-Output ''
Write-Output 'Next: classify each entry before deleting anything.'
Write-Output 'See references/app-cache-atlas.md for per-application safe/unsafe subdirectories.'
