# Case Study: 19 GB -> 62.7 GB Free on a 299 GB System Drive

A fully worked run on a real Windows 11 workstation (game development + content
creation: Unreal Engine, JetBrains IDEs, .NET, video editing, several chat clients).
Paths are anonymized; the numbers are measured, not estimated.

**Result: 43.7 GB recovered in a single session, no user data lost.** Roughly half was
deleted cache, half was relocated to a second SSD - so the relocated portion cannot
grow back on C:.

## Starting state

| Volume | Size | Free | Free % |
|---|---|---|---|
| C: (system) | 299.1 GB | **19.0 GB** | 6.3% |
| D: (target) | 631.1 GB | 179.4 GB | 28.4% |

Top-level distribution on C:

```
110.8 GB  C:\Users
 67.6 GB  C:\Windows
 60.1 GB  C:\Program Files
 22.7 GB  C:\ProgramData
 20.2 GB  C:\Program Files (x86)
```

`C:\Users` was the target: 73 GB of it was a single user's `AppData`.

## Prior incident that set the tone

Two weeks earlier the same drive had reached zero free bytes. The result was not an
error dialog - Chrome's `History` SQLite database was truncated to an empty shell, and
Chrome continued running for days without recording anything because it never reopened
the file. The loss was only noticed later, and local history from before the incident
was unrecoverable (the only shadow copy post-dated the event; cloud-synced history
remained available through the account's activity page).

This is why the skill treats a nearly-full disk as an active data-loss risk and why
"clean early" is the default advice.

## What was found and what was decided

| Item | Size | Decision |
|---|---|---|
| Agent session transcripts (one project) | 17.4 GB | **Relocate** - user history, `--resume` depends on it |
| Chat client data directory | 10.6 GB | **Split**: delete 6.7 GB pure cache, relocate the 3.7 GB remainder |
| Abandoned IDE installer unpack directory in `%TEMP%` | 7.4 GB | Delete |
| GPU driver update packages | 6.7 GB | Delete |
| DirectX shader cache | 4.8 GB | Delete (rebuilds automatically) |
| .NET package cache | 4.1 GB | **Relocate** via env var |
| Browser-automation binaries | 2.6 GB | **Relocate** via env var |
| Game engine DDC + content-addressed store | 2.0 GB | **Relocate** (0.7 GB of it an abandoned backup - deleted) |
| Misc `%TEMP%` older than 7 days | ~0.6 GB | Delete |
| Launcher web cache | 0.1 GB | Delete |

Explicitly left alone: browser profiles (2.4 GB), messaging app data (7.5 GB - the
user was directed to the in-app storage setting instead), `Windows\Installer` (6.9 GB),
`WinSxS` (13.3 GB), System Restore points, and the user's own project directories.

## Execution notes

### The chat client (the interesting one)

10.6 GB in `%APPDATA%\<Client>`, a Chromium-derived layout with five account profiles.
Deleting the folder would have cost the login session and local drafts. Instead, a
recursive walk collected only directories named `Cache_Data`, `Code Cache`, `GPUCache`,
the shader caches, and `Service Worker\CacheStorage` - 58 directories, 6.7 GB, plus
0.7 GB of SDK logs.

The largest single items were two `Service Worker\CacheStorage` directories at
1.58 GB and 1.56 GB - which is why folder-level thinking fails here: the parent
`Service Worker` directory also contains `Database`, which must stay.

The remaining 3.7 GB (login state, message cache, downloaded assets) was relocated by
junction. The client has no setting for its overall data path - only for the download
directory. After restart it retained its login and new writes landed on D:.

### Verified byte-for-byte, every time

Each of the four relocations passed an independent recount before its source was
deleted:

| Moved | Bytes | Files |
|---|---|---|
| Chat client data | 3,964,025,593 | 24,475 |
| Agent transcripts | 17,372,121,792 | 12,386 |
| Package cache | 4,374,538,578 | 21,371 |
| Browser binaries | 2,831,076,884 | 2,317 |

Source and destination matched exactly in all four cases. Had any not matched, the
source would have been kept and the run stopped.

### What did not work

The DirectX shader cache directory could not be renamed - the GPU vendor's container
service held handles inside it. Contents were cleared (4.8 GB) but the junction could
not be created; that step was deferred to after a reboot. This is the expected
outcome of the `Rename-Item` lock probe and the right response is to defer, not to
force.

### Encoding bug, caught live

The first cleanup helper script was written as UTF-8 without BOM with Chinese
comments. Under PowerShell 5.1 it ran, reported success, and freed 0.04 GB instead of
6.7 GB: the mis-decoded comment bytes had swallowed the statement that pushed the root
onto the traversal stack, so `New-Object` returned `$null` and the search silently
found zero directories. Rewritten in pure ASCII, the same logic found all 58.

The lesson is in `windows-pitfalls.md` section 1. The script *appeared to succeed* -
which is why the "measure what was actually freed" habit matters.

## Ending state

| Volume | Free before | Free after |
|---|---|---|
| C: | 19.0 GB (6.3%) | **62.7 GB (21%)** |

Four junctions and two environment variables now keep the largest recurring consumers
off the system drive permanently.

## Post-run record

Leave the user with an explicit record, because a junction is invisible six months
later:

```
D:\AppData\<Client>            <- junction from %APPDATA%\<Client>
D:\ClaudeData\projects\<name>  <- junction from ~\.claude\projects\<name>
D:\UECache\UnrealEngineCommon  <- junction from %LOCALAPPDATA%\UnrealEngine\Common
D:\PackageCaches\nuget\packages    <- NUGET_PACKAGES
D:\PackageCaches\ms-playwright     <- PLAYWRIGHT_BROWSERS_PATH
```

Also worth flagging: open IDEs and terminals must be restarted before they see the new
environment variables, and other volumes on the machine were separately near capacity
(0.7% and 2% free) - a full-disk risk does not stop at C:.
