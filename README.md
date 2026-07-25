# DriveKeeper · C盘清理大师

**Free your C: drive — and keep it free.**

Cleaners delete, and the space comes back in about two weeks. DriveKeeper maps it away,
so it doesn't.

A Claude Code skill and standalone PowerShell toolkit that frees a full Windows C: drive
and then keeps it free — by relocating the directories that actually regrow onto another
drive with NTFS junctions and environment variables. Applications keep writing to the
same path; the bytes land somewhere else.

[中文文档](README.zh-CN.md) · [Documentation site](https://linad3d.github.io/drivekeeper/)

---

## The problem with cleaning

Deleting a cache buys you a few weeks. Then you do it again. Measured on one real
workstation, 13 days after a cleanup:

| What was done to it | At cleanup | 13 days later | Where the growth landed |
|---|---|---|---|
| **Deleted only** — `%LOCALAPPDATA%\Temp` | 0 GB | **10.94 GB** | back on C: |
| **Deleted only** — NVIDIA `DXCache` | 0 GB | 0.31 GB | back on C: |
| **Relocated** — Feishu/Lark data | 3.69 GB | **9.45 GB** | **D: — 5.76 GB of new cache, none on C:** |
| **Relocated** — agent session transcripts | 16.18 GB | 16.19 GB | D: |
| **Relocated** — NuGet + Playwright | 6.71 GB | 6.71 GB | D: |

**11.25 GB crawled back onto C: in 13 days — about 0.87 GB/day.** A delete-only cleanup
is undone in roughly two weeks.

Over the same period the relocated set grew 5.32 GB net. **Not one byte of it went to
C:.** That is the entire argument for mapping instead of just deleting: a junction is a
filesystem-level redirect, so the application still opens the same path it always did
and never learns that its data now lives on another volume.

## How it compares

| | 360 / Tencent PC suites | CCleaner / Storage Sense | **DriveKeeper** |
|---|---|---|---|
| One-click junk cleanup | Yes | Yes | Yes — allowlist, **dry-run by default** |
| Relocates with junctions | Yes (their "move from C:" feature) | No | Yes |
| **Who decides what moves** | **The vendor's built-in software list** | — | **You do** — any directory, app, or toolchain |
| Dev toolchain caches via env vars | No | No | Yes (NuGet, npm, pip, Playwright, Cargo, Gradle, UE DDC) |
| Per-subdirectory safe/unsafe rules | No | No | Yes — 30+ apps, and you can add your own |
| Byte-level verification before deleting the source | Not documented | N/A | Yes — mismatch aborts |
| Background service, ads, upsells | Yes | Some | **None** — it runs and exits |
| Uninstall | Uninstaller flow | Uninstaller flow | **Delete a folder** |
| Open source | No | No | MIT |

To be fair to them: the big Chinese PC suites *do* use symbolic links to move installed
software off C:, and that part works. The differences that matter are what gets moved and
what comes attached.

**You point it at anything.** There is no vendor list to wait on:

```powershell
.\Move-AppData.ps1 -Source "$env:APPDATA\SomeAppNobodySupports" -Destination "D:\AppData\SomeApp"
```

Storage Sense, for reference, only manages the system drive, [explicitly does not touch
browser caches](https://www.makeuseof.com/windows-has-a-built-in-auto-cleanup-tool-but-its-default-settings-are-almost-useless/),
skips app temp files from Teams/Spotify/Discord, and by default only runs once the disk
is already nearly full.

## How long it takes

The documented run took **about 25 minutes end to end**: a few minutes scanning, the
deletions, then ~11 minutes copying 29 GB across five relocations (SSD to SSD). That is
a **one-time cost**. Compare it to re-running a cleaner every two weeks, forever.

It recovered **43.7 GB** in that session — 19.0 GB free → 62.7 GB on a 299 GB system
drive, with zero data lost. Thirteen days later the drive was still at 61.4 GB free.

## Safety

Space is easy to reclaim if you don't mind losing things. This is built the other way
round:

- **Deletion is allowlist-only.** It cannot be pointed at an arbitrary folder — that is
  structural, not a policy you have to trust.
- **Dry-run by default.** Nothing is removed until you pass `-Execute`.
- **Anything a human created or accumulated gets moved, never deleted.**
- **Byte-level verification before any source is deleted.** Total bytes *and* file count
  are recounted independently on both sides; a mismatch aborts and restores the original.

The hard part isn't deleting — it's knowing which *subdirectory* of an app is disposable.
In a Chromium-based desktop app, `Service Worker\CacheStorage` is disposable and often
over 1.5 GB per profile, but its sibling `Service Worker\Database` is not, and
`Local Storage` holds your login token. Folder-level thinking logs you out. The skill
ships a [per-application atlas](skills/windows-disk-cleanup/references/app-cache-atlas.md)
of exactly these distinctions.

## Install

```bash
git clone https://github.com/linad3d/drivekeeper.git
cp -r drivekeeper/skills/windows-disk-cleanup ~/.claude/skills/
```

On Windows PowerShell:

```powershell
git clone https://github.com/linad3d/drivekeeper.git
Copy-Item -Recurse drivekeeper\skills\windows-disk-cleanup "$env:USERPROFILE\.claude\skills\"
```

Then describe the problem:

> my C drive is down to 8GB, figure out what's eating it and clean up what's safe

It also triggers on Chinese phrasing (`C盘满了`, `C盘爆红`, `C盘清理`) and on relocation
requests (`move the Feishu cache to D:`, `point Unreal's DDC at another drive`).

## Use the scripts directly

No Claude required — the four PowerShell scripts work standalone:

```powershell
# 1. See what is actually consuming space
.\Scan-DiskUsage.ps1 -Path C:\ -MinGB 0.3

# 2. Preview a cleanup - deletes nothing
.\Invoke-SafeClean.ps1

# 3. Actually clean the categories you chose
.\Invoke-SafeClean.ps1 -Category GPU,DevTools -Execute

# 4. Relocate anything, listed or not
.\Move-AppData.ps1 -Source "$env:APPDATA\SomeApp" -Destination "D:\AppData\SomeApp"

# 5. Verify junctions, env vars, and that writes really land on the new drive
.\Test-Migration.ps1
.\Test-Migration.ps1 -Watch "D:\AppData\SomeApp"
```

## What it knows about

Per-app safe/unsafe subdirectory maps and the right relocation mechanism for each:

**Chat & collaboration** — Feishu/Lark, Slack, Discord, Teams, WeChat, WeCom
**Game dev** — Unreal Engine (DDC + Zen Store), Epic Games Launcher
**GPU** — NVIDIA DXCache / NV_Cache / driver payloads, AMD, Direct3D
**Toolchains** — NuGet, npm, pip, Yarn, Cargo, Gradle, Go, Playwright, Electron, JetBrains
**AI agents** — Claude Code session transcripts
**Windows** — Temp, Windows Update, crash dumps, WinSxS (and what never to touch)

Anything not on this list still works — the atlas tells you *which subdirectory is safe*,
while `Move-AppData.ps1` moves whatever you point it at.

## Choosing a relocation method

Three mechanisms, preferred in this order:

1. **The application's own setting** — best, because the app migrates its own data.
2. **An environment variable** the toolchain documents — `NUGET_PACKAGES`,
   `PLAYWRIGHT_BROWSERS_PATH`, `UE-LocalDataCachePath`, and others.
3. **An NTFS junction** — the universal fallback, for the majority of apps that offer
   neither.

The junction path follows a sequence that is safe to interrupt at any point:

```
lock probe (rename in place) -> robocopy -> INDEPENDENT RECOUNT of bytes + files
                             -> delete source (only if the recount matched)
                             -> mklink /J -> restart app, confirm writes land on target
```

Until the source is deleted the original data is fully intact. `Move-AppData.ps1`
enforces this and refuses to continue on a mismatch.

## FAQ

**Will the space come back?**
Not for anything relocated. In the 13-day measurement above, relocated apps produced
5.32 GB of new data and all of it landed on the destination drive. Deleted-only items
regrew 11.25 GB on C: over the same period — which is why the skill relocates rather
than just deletes wherever it can.

**Will I lose my chat history?**
No. The skill never deletes message stores, browser profiles, or drafts. For Chromium
apps it removes only HTTP/GPU/code caches and leaves login state intact. For WeChat and
WeCom it does not touch the data at all — it points you at the app's own storage setting.

**Can it move an app that isn't in the atlas?**
Yes. `Move-AppData.ps1` takes any source and destination. The atlas documents which
subdirectories are safe for apps that have been verified; the relocation machinery is
generic.

**Is a junction safe? Will apps break?**
A junction is a filesystem-level redirect resolved below the application layer, so apps
treat it as a real directory. It requires NTFS on both sides and the same machine — do
not point one at a network share or a removable drive.

**Does deleting the Unreal DDC break my project?**
No. Epic's documentation states DDC contents are disposable and regenerated from
`.uasset` files. Relocating is still better than deleting, since deleting means
recompiling shaders.

**robocopy returned exit code 1 — did it fail?**
No. robocopy exit codes are a bit field: anything below 8 is success (`1` means files
were copied). Testing `$?` or `$LASTEXITCODE -ne 0` reports a perfect copy as a failure.

**Why do my scripts break with weird null errors?**
Windows PowerShell 5.1 reads a UTF-8 file without BOM as ANSI. Non-ASCII characters in
comments corrupt the byte stream and can swallow adjacent statements — variables silently
become `$null` and the script half-runs without erroring. Keep helper `.ps1` files pure
ASCII, or save as UTF-8 with BOM. See
[windows-pitfalls.md](skills/windows-disk-cleanup/references/windows-pitfalls.md).

**My IDE still uses the old package cache after I set the env var.**
Processes started before the variable was set inherited the old environment. Restart the
IDE or terminal.

**Why clean early rather than when the disk is actually full?**
Because a Windows volume that reaches zero free bytes does not fail loudly — it silently
corrupts whatever was mid-write. In the incident behind this project, a full C: drive
truncated Chrome's `History` SQLite database into an empty shell, and Chrome kept running
without recording anything until it was restarted. The loss was found days later.

## Documentation

| File | What is in it |
|---|---|
| [SKILL.md](skills/windows-disk-cleanup/SKILL.md) | The workflow Claude follows |
| [app-cache-atlas.md](skills/windows-disk-cleanup/references/app-cache-atlas.md) | Per-application: what is safe to delete, what must stay |
| [relocation-methods.md](skills/windows-disk-cleanup/references/relocation-methods.md) | App setting vs environment variable vs junction |
| [windows-pitfalls.md](skills/windows-disk-cleanup/references/windows-pitfalls.md) | PowerShell, encoding, robocopy, locking gotchas |
| [case-study.md](skills/windows-disk-cleanup/references/case-study.md) | The full 43.7 GB run plus the 13-day follow-up measurement |
| [evals/README.md](skills/windows-disk-cleanup/evals/README.md) | Trigger evaluation: 100% accuracy over 19 scored queries |

## Requirements

Windows 10/11 · PowerShell 5.1+ · NTFS on source and destination · elevation for
`mklink`, `C:\ProgramData`, and `C:\Windows\Temp`.
[Claude Code](https://claude.com/claude-code) is optional — the scripts run standalone.

## Contributing

The most useful contribution is an addition to the application atlas: a named app, which
subdirectories are regenerable, which hold state, and how you verified it. Firsthand
findings only — an untested guess in that table is how someone loses their login.

## License

MIT — see [LICENSE](LICENSE).
