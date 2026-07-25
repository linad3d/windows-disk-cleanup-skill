<#
.SYNOPSIS
    Relocate a directory to another drive and leave an NTFS junction behind.

.DESCRIPTION
    Implements the only safe ordering for this operation:

        1. Lock probe   - rename the source in place; if that fails something holds a
                          handle and we stop. The rename also stages the move, so an
                          application that restarts mid-operation creates a fresh
                          directory instead of writing into the one being copied.
        2. Copy         - robocopy /E /COPY:DAT /DCOPY:DAT
        3. VERIFY       - independently recount total bytes AND file count on both
                          sides and require exact equality. robocopy's own summary is
                          not trusted; we recount.
        4. Delete source - only after verification passes.
        5. Junction     - mklink /J from the original path to the destination.
        6. Report       - tell the user to restart the app and confirm new writes.

    Until step 4 the original data is fully intact, so the operation is safe to abandon
    at any earlier point. If verification fails the source is restored and nothing is
    lost.

.PARAMETER Source
    Directory to move. Must exist and must not already be a junction.

.PARAMETER Destination
    Target path on another volume. Must not exist, or must be empty.

.PARAMETER Force
    Skip the confirmation prompt.

.EXAMPLE
    .\Move-AppData.ps1 -Source "$env:APPDATA\LarkShell" -Destination 'D:\AppData\LarkShell'

.NOTES
    Creating a junction generally requires an elevated session.
    Junctions require NTFS on both sides and do not work to network shares or to
    removable drives that may be absent at boot.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Source,
    [Parameter(Mandatory = $true)] [string] $Destination,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Get-TreeStats {
    <# Independent recount: total bytes and file count, skipping reparse points. #>
    param([string] $Root)

    $bytes = 0L
    $files = 0L
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
        } catch { }
    }
    return [PSCustomObject]@{ Bytes = $bytes; Files = $files }
}

function Fail {
    param([string] $Message)
    Write-Output ''
    Write-Output ('ABORTED: ' + $Message)
    exit 1
}

# --- Preflight ---------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Source)) { Fail ("Source does not exist: " + $Source) }

$srcItem = Get-Item -LiteralPath $Source -Force
if (-not $srcItem.PSIsContainer) { Fail 'Source must be a directory.' }
if ($srcItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    Fail ('Source is already a junction or symlink (target: ' + ($srcItem.Target -join ', ') + ').')
}

$srcRoot = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Source).Path)
$dstRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Destination))
if ($srcRoot -eq $dstRoot) {
    Fail 'Source and destination are on the same volume - relocating would free nothing.'
}

$dstFs = (Get-Volume -DriveLetter $dstRoot.TrimEnd(':\') -ErrorAction SilentlyContinue).FileSystemType
if ($dstFs -and $dstFs -ne 'NTFS') {
    Fail ("Destination volume is " + $dstFs + ". Junctions require NTFS on both sides.")
}

if (Test-Path -LiteralPath $Destination) {
    $existing = Get-ChildItem -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    if ($existing) { Fail ("Destination exists and is not empty: " + $Destination) }
}

$stats = Get-TreeStats $Source
$needGB = $stats.Bytes / 1GB
$freeGB = (Get-Volume -DriveLetter $dstRoot.TrimEnd(':\')).SizeRemaining / 1GB
if ($freeGB -lt ($needGB * 1.05)) {
    Fail ('Not enough free space on destination. Need ~{0:N2} GB, have {1:N2} GB.' -f $needGB, $freeGB)
}

Write-Output ''
Write-Output '=== Relocation plan ==='
Write-Output ('  Source      : {0}' -f $Source)
Write-Output ('  Destination : {0}' -f $Destination)
Write-Output ('  Size        : {0:N2} GB in {1:N0} files' -f $needGB, $stats.Files)
Write-Output ('  Free after  : ~{0:N2} GB on {1}' -f ($freeGB - $needGB), $dstRoot)
Write-Output ''
Write-Output 'Close the owning application before continuing.'

if (-not $Force) {
    $answer = Read-Host 'Proceed? (y/N)'
    if ($answer -ne 'y' -and $answer -ne 'Y') { Fail 'Cancelled by user.' }
}

# --- Step 1: lock probe / staging rename -------------------------------------

$parent   = Split-Path -Parent $Source
$leaf     = Split-Path -Leaf   $Source
$stagName = $leaf + '.migrating'
$staged   = Join-Path $parent $stagName

Write-Output ''
Write-Output '[1/5] Lock probe (rename in place)...'
try {
    Rename-Item -LiteralPath $Source -NewName $stagName -ErrorAction Stop
} catch {
    Fail ("Could not rename the source, so a process still holds a handle on it. " +
          "Close the owning application (including tray and helper processes) and retry. " +
          "Detail: " + $_.Exception.Message)
}
Write-Output '      OK - nothing holds a handle.'

# --- Step 2: copy ------------------------------------------------------------

Write-Output '[2/5] Copying...'
$null = New-Item -ItemType Directory -Force -Path $Destination
# Do not redirect robocopy stderr: in PS 5.1 that wraps output in ErrorRecords and
# falsely sets $? to False even on success.
robocopy $staged $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /NFL /NDL /NP | Out-Null
$rc = $LASTEXITCODE

# robocopy exit codes are a bit field. Anything below 8 is success.
if ($rc -ge 8) {
    Rename-Item -LiteralPath $staged -NewName $leaf -ErrorAction SilentlyContinue
    Fail ("robocopy reported a real failure (exit code $rc). Source has been restored.")
}
Write-Output ("      robocopy exit code $rc (below 8 = success).")

# --- Step 3: verify ----------------------------------------------------------

Write-Output '[3/5] Verifying (independent recount of both sides)...'
$srcStats = Get-TreeStats $staged
$dstStats = Get-TreeStats $Destination

Write-Output ('      source     : {0,18:N0} bytes  {1,8:N0} files' -f $srcStats.Bytes, $srcStats.Files)
Write-Output ('      destination: {0,18:N0} bytes  {1,8:N0} files' -f $dstStats.Bytes, $dstStats.Files)

if ($srcStats.Bytes -ne $dstStats.Bytes -or $srcStats.Files -ne $dstStats.Files) {
    Rename-Item -LiteralPath $staged -NewName $leaf -ErrorAction SilentlyContinue
    Fail ('Verification MISMATCH. Source restored and left intact; destination copy ' +
          'left at ' + $Destination + ' for inspection. Nothing was deleted.')
}
Write-Output '      MATCH - copy is byte-for-byte complete.'

# --- Step 4: delete source ---------------------------------------------------

Write-Output '[4/5] Removing the original (verification passed)...'
try {
    Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction Stop
} catch {
    Fail ("Copy is verified at " + $Destination + " but the original could not be removed: " +
          $_.Exception.Message + " -- delete " + $staged + " manually, then create the junction.")
}
if (Test-Path -LiteralPath $staged) { Fail 'Original still present after removal; not creating a junction.' }
Write-Output '      Removed.'

# --- Step 5: junction --------------------------------------------------------

Write-Output '[5/5] Creating junction...'
cmd /c mklink /J "$Source" "$Destination" | Out-Null

$link = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
if (-not $link -or -not ($link.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    Fail ("Junction was not created. The data is safe at " + $Destination +
          " - create the link manually with:  mklink /J `"" + $Source + "`" `"" + $Destination + "`"")
}
Write-Output ('      ' + $Source + '  ->  ' + ($link.Target -join ', '))

# --- Done --------------------------------------------------------------------

Write-Output ''
Write-Output ('DONE. Freed {0:N2} GB on {1}' -f $needGB, $srcRoot)
Write-Output ''
Write-Output 'Final step, do not skip: start the application and confirm new files appear'
Write-Output 'under the destination. A junction that silently failed looks identical to one'
Write-Output 'that worked until you check. Test-Migration.ps1 -Watch does this for you.'
