# Windows / PowerShell Pitfalls

Every item here cost real debugging time during actual cleanup runs. Read before
writing helper scripts for this task.

## 1. Write helper `.ps1` files in pure ASCII

**Windows PowerShell 5.1 reads a UTF-8 file with no BOM as ANSI (the system code
page).** Any non-ASCII character - a comment in Chinese, a curly quote, an em dash -
is decoded into different bytes than you wrote.

The failure mode is *not* a clean error. The corrupted byte sequence can swallow the
statements next to it. Observed in practice: a script with Chinese comments ran with
`New-Object` and `Join-Path` calls silently evaluating to `$null`, producing
`You cannot call a method on a null-valued expression` several lines away from the
actual cause, while the rest of the script ran normally and reported success.

Rules:

- Keep generated `.ps1` content ASCII-only, including comments and output strings.
- If you need non-ASCII output, write the file as **UTF-8 with BOM**, which 5.1 detects
  correctly.
- PowerShell 7+ defaults to UTF-8 and does not have this problem - but do not assume
  the user has it.

Diagnostic: if a script produces null-reference errors on lines that are obviously
fine, check for non-ASCII bytes before debugging the logic.

## 2. `robocopy` exit codes are a bit field, not a boolean

| Code | Meaning |
|---|---|
| 0 | No files copied, no mismatch - success |
| 1 | Files copied successfully |
| 2 | Extra files/dirs in destination |
| 3 | 1 + 2 |
| 4 | Mismatched files/dirs |
| 8 | **Some files could not be copied - first real failure** |
| 16 | Fatal error |

**Anything below 8 is success.** Testing `$?`, `$LASTEXITCODE -ne 0`, or wrapping in
`try/catch` will report a perfect copy as a failure. Test `$LASTEXITCODE -lt 8`.

Additionally, in PowerShell 5.1 redirecting a native command's stderr (`2>&1`) wraps
each line in an ErrorRecord and sets `$?` to `$false` even on exit code 0. Do not
redirect robocopy's stderr.

## 3. Do not parse localized tool output

On non-English Windows, `robocopy`, `DISM`, and `chkdsk` emit localized text, often
rendered as mojibake through a mismatched console code page. Never scrape it for
counts or sizes. Compute what you need yourself.

## 4. Measure directory sizes with a manual stack, and skip reparse points

`Get-ChildItem -Recurse` is slow on large trees, throws on permission-denied
subtrees, and - critically - **follows junctions**, so a relocated folder gets counted
twice or sends you into a loop.

Use .NET enumeration with an explicit stack:

```powershell
$stack = New-Object 'System.Collections.Generic.Stack[string]'
$stack.Push($root)
while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    try {
        $di = New-Object System.IO.DirectoryInfo($dir)
        foreach ($fsi in $di.EnumerateFileSystemInfos()) {
            if ($fsi -is [System.IO.DirectoryInfo]) {
                if ($fsi.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($fsi.FullName)
            } else {
                try { $total += $fsi.Length } catch {}
            }
        }
    } catch {}   # unreadable subtree - skip, do not abort
}
```

Three properties matter: it skips reparse points, it swallows per-directory access
errors instead of aborting the whole scan, and it is iterative so deep trees do not
blow the stack.

Note `New-Object 'System.Collections.Generic.Stack[string]'` needs the type name
quoted - unquoted, PowerShell parses the brackets as an index expression and hands you
`$null`.

## 5. `Rename-Item` is the cheapest lock probe

Before deleting or moving a large directory, rename it in place:

```powershell
try   { Rename-Item -LiteralPath $dir -NewName ($name + '.migrating') -ErrorAction Stop }
catch { <# something holds a handle - stop #> }
```

If the rename succeeds, no process holds a handle and the subsequent delete/move will
work. If it fails, a process still has it open - stop rather than forcing it. This is
faster than probing files individually and has no side effects: on failure nothing
changed, on success you have also staged the directory for the move.

It doubles as a safety interlock during migration: renaming first means a concurrently
starting application recreates a fresh empty directory instead of writing into the one
you are copying.

## 6. Elevation and permissions

- `C:\ProgramData`, `C:\Windows\Temp`, and `mklink` need an elevated session.
- Check with:
  ```powershell
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
  ```
- Some directories are ACL-protected against even Administrators (`C:\Windows\Installer`
  subtrees, WinSxS). Do not fight the ACL - those paths are on the do-not-touch list
  for good reason.

## 7. Deleting robustly

`Remove-Item -Recurse -Force` aborts the whole batch when one file is locked. For
cleanup work, degrade gracefully:

```powershell
try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop }
catch {
    Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch {} }
    try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop } catch {}
}
```

Sorting by path length descending deletes deepest-first, so directories are empty by
the time they are removed. Then re-measure and report what was actually freed rather
than what you attempted - partial success is normal and should be stated honestly.

Always use `-LiteralPath`. Application cache directories routinely contain `[`, `]`,
and `` ` `` characters that `-Path` interprets as wildcards.

## 8. Some environments block certain command shapes

Automation harnesses and endpoint-protection agents sometimes statically inspect
command strings and refuse ones containing `rd /s /q`, wildcards, or paths that
pattern-match a protected location - occasionally with an error naming a nonexistent
path like `/s`. The behaviour can be inconsistent between identical invocations.

Workaround: put the deletion logic in a `.ps1` file (using `Remove-Item -LiteralPath`
plus `try/catch`) and invoke it as `& 'script.ps1'`. This also produces a reviewable
artifact of exactly what was deleted.

## 9. Killing an application before touching its data

```powershell
taskkill /IM App.exe          # graceful - lets it flush and close databases
Start-Sleep -Seconds 4
if (Get-Process App -ErrorAction SilentlyContinue) {
    taskkill /IM App.exe /T /F    # force only if it did not exit
}
```

Try graceful first. Chromium-based apps flush SQLite on clean shutdown; force-killing
one and then deleting parts of its profile is a good way to corrupt it. Also account
for tray processes and helper subprocesses - a single app can be a dozen PIDs.

## 10. Verify migrations by watching new writes

A junction that silently failed and a junction that worked look identical from the
original path. After relocating, start the application and confirm files with a recent
timestamp appear under the *destination*:

```powershell
Get-ChildItem $destination -Recurse -Depth 1 -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-2) }
```

That is the only check that proves the redirect is live rather than merely present.
