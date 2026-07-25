# Windows Disk Cleanup Skill

**A Claude Code skill that rescues a full Windows C: drive without losing any user data.**
It scans what is actually eating space, deletes only regenerable caches, and relocates
everything else to another drive with NTFS junctions and environment variables — so the
space stays recovered.

[中文文档](README.zh-CN.md) · [Documentation site](https://linad3d.github.io/windows-disk-cleanup-skill/)

> Built from a real rescue that recovered **43.7 GB in one session** on a 299 GB system
> drive (19.0 GB → 62.7 GB free), with zero data loss. Every number in
> [the case study](skills/windows-disk-cleanup/references/case-study.md) is measured, not estimated.

---

## Why this exists

A Windows volume that reaches zero bytes does not fail loudly — **it silently corrupts
whatever was mid-write.** In the incident this skill was built from, a full C: drive
truncated Chrome's `History` SQLite database into an empty shell, and Chrome kept running
without recording anything until it was restarted. The loss was found days later.

Most cleanup tools optimize for how much they delete. This one optimizes for *not
destroying anything*, then for making the space permanent:

- **Deletes only from an allowlist** of known-regenerable cache paths. It cannot be
  pointed at an arbitrary folder — that is structural, not a policy.
- **Dry-run by default.** Nothing is removed until you pass `-Execute`.
- **Relocates instead of deleting** anything a human created or accumulated.
- **Byte-level verification before any source is deleted.** If the recount does not
  match exactly, the operation stops and the original is restored.

## What makes it different

Most guides tell you to delete `%TEMP%` and empty the recycle bin. The hard part is
knowing which *subdirectory* of an app is disposable — because that is where the space
actually is, and where the data loss actually happens.

| | Typical cleanup tool | This skill |
|---|---|---|
| Scope | Whole folders | Per-subdirectory, per-application |
| Login state | Frequently destroyed | Explicitly preserved |
| Safety | "Are you sure?" | Allowlist + dry-run + byte verification |
| Permanence | Space grows back | Junctions and env vars keep it off C: |

Concrete example: in a Chromium-based desktop app, `Service Worker\CacheStorage` is
disposable and often over 1.5 GB per profile — but its sibling `Service Worker\Database`
is not, and `Local Storage` holds your login token. Folder-level thinking loses your
session. The skill ships a
[per-application atlas](skills/windows-disk-cleanup/references/app-cache-atlas.md)
of exactly these distinctions.

## Install

```bash
git clone https://github.com/linad3d/windows-disk-cleanup-skill.git
cp -r windows-disk-cleanup-skill/skills/windows-disk-cleanup ~/.claude/skills/
```

On Windows PowerShell:

```powershell
git clone https://github.com/linad3d/windows-disk-cleanup-skill.git
Copy-Item -Recurse windows-disk-cleanup-skill\skills\windows-disk-cleanup "$env:USERPROFILE\.claude\skills\"
```

Then just tell Claude Code what is wrong:

> my C drive is down to 8GB, figure out what's eating it and clean up what's safe

It also triggers on Chinese phrasing (`C盘满了`, `C盘爆红`, `C盘清理`) and on
relocation requests (`move the Feishu cache to D:`, `point Unreal's DDC at another drive`).

## Use the scripts directly

The four PowerShell scripts work standalone, without Claude:

```powershell
# 1. See what is actually consuming space
.\Scan-DiskUsage.ps1 -Path C:\ -MinGB 0.3

# 2. Preview a cleanup - deletes nothing
.\Invoke-SafeClean.ps1

# 3. Actually clean the categories you chose
.\Invoke-SafeClean.ps1 -Category GPU,DevTools -Execute

# 4. Relocate something too valuable to delete
.\Move-AppData.ps1 -Source "$env:APPDATA\SomeApp" -Destination "D:\AppData\SomeApp"

# 5. Verify junctions, env vars, and that writes really land on the new drive
.\Test-Migration.ps1
.\Test-Migration.ps1 -Watch "D:\AppData\SomeApp"
```

## Applications covered

Per-app safe/unsafe subdirectory maps and the right relocation mechanism for each:

**Chat & collaboration** — Feishu/Lark, Slack, Discord, Teams, WeChat, WeCom
**Game dev** — Unreal Engine (DDC + Zen Store), Epic Games Launcher
**GPU** — NVIDIA DXCache / NV_Cache / driver payloads, AMD, Direct3D
**Toolchains** — NuGet, npm, pip, Yarn, Cargo, Gradle, Go, Playwright, Electron, JetBrains
**AI agents** — Claude Code session transcripts
**Windows** — Temp, Windows Update, crash dumps, WinSxS (and what never to touch)

## How relocation works

Three mechanisms, preferred in this order:

1. **The application's own setting** — best, because the app migrates its own data.
2. **An environment variable** the toolchain documents — `NUGET_PACKAGES`,
   `PLAYWRIGHT_BROWSERS_PATH`, `UE-LocalDataCachePath`, and others.
3. **An NTFS junction** — the universal fallback. Applications open a junction as a real
   directory, so no app support is required.

The junction path follows a sequence that is safe to interrupt at any point:

```
lock probe (rename in place) -> robocopy -> INDEPENDENT RECOUNT of bytes + files
                             -> delete source (only if the recount matched)
                             -> mklink /J -> restart app, confirm writes land on target
```

Until the source is deleted, the original data is fully intact. `Move-AppData.ps1`
enforces this and refuses to continue on a mismatch.

## FAQ

**Will I lose my chat history?**
No. The skill never deletes message stores, browser profiles, or drafts. For Chromium
apps it removes only HTTP/GPU/code caches and leaves login state intact. For WeChat and
WeCom it does not touch the data at all — it points you at the app's own storage setting.

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
ASCII, or save as UTF-8 with BOM. This cost real debugging time; see
[windows-pitfalls.md](skills/windows-disk-cleanup/references/windows-pitfalls.md).

**My IDE still uses the old package cache after I set the env var.**
Processes started before the variable was set inherited the old environment. Restart the
IDE or terminal.

## Documentation

| File | What is in it |
|---|---|
| [SKILL.md](skills/windows-disk-cleanup/SKILL.md) | The workflow Claude follows |
| [app-cache-atlas.md](skills/windows-disk-cleanup/references/app-cache-atlas.md) | Per-application: what is safe to delete, what must stay |
| [relocation-methods.md](skills/windows-disk-cleanup/references/relocation-methods.md) | App setting vs environment variable vs junction |
| [windows-pitfalls.md](skills/windows-disk-cleanup/references/windows-pitfalls.md) | PowerShell, encoding, robocopy, locking gotchas |
| [case-study.md](skills/windows-disk-cleanup/references/case-study.md) | The full 43.7 GB run, with real numbers |

## Requirements

Windows 10/11 · PowerShell 5.1+ · NTFS on source and destination · elevation for
`mklink`, `C:\ProgramData`, and `C:\Windows\Temp`.
[Claude Code](https://claude.com/claude-code) is optional — the scripts run standalone.

## Contributing

The most useful contribution is an addition to the application atlas: a named app, which
subdirectories are regenerable, which hold state, and how you verified it. Firsthand
findings only — an untested guess in this table is how someone loses their login.

## License

MIT — see [LICENSE](LICENSE).
