# Application Cache Atlas

Per-application map of what is safe to delete, what must be preserved, and what is
better relocated than deleted. **Consult the relevant section before acting on any
named application.**

The recurring lesson: *a single application data directory usually mixes disposable
cache and irreplaceable state.* Deleting the whole folder to "clear the cache" is how
people lose login sessions and local history. Almost every entry below is a
subdirectory-level decision, not a folder-level one.

## Contents

- [Chromium-based desktop apps (the general pattern)](#chromium-based-desktop-apps)
- [Feishu / Lark](#feishu--lark)
- [WeChat / WeCom / QQ](#wechat--wecom--qq)
- [Browsers (Chrome, Edge)](#browsers)
- [Unreal Engine and Epic Games](#unreal-engine-and-epic-games)
- [NVIDIA](#nvidia)
- [Developer toolchains](#developer-toolchains)
- [AI coding agents](#ai-coding-agents)
- [Windows itself](#windows-itself)

---

## Chromium-based desktop apps

Most modern desktop chat/collaboration clients (Feishu/Lark, Slack, Discord, Teams,
and many others) are Electron or CEF applications, so they share Chromium's profile
layout. Learn this table once and it applies to all of them.

| Subdirectory | Verdict | Why |
|---|---|---|
| `Cache\Cache_Data` | **Delete** | HTTP response cache; refetched on demand |
| `Code Cache` | **Delete** | Compiled JS bytecode cache; rebuilt on next run |
| `GPUCache`, `ShaderCache`, `GrShaderCache`, `DawnCache`, `GraphiteDawnCache` | **Delete** | GPU shader/pipeline caches; rebuilt |
| `Service Worker\CacheStorage` | **Delete** | Service-worker HTTP cache; refetched |
| `Service Worker\Database` | **KEEP** | Service-worker registrations; deleting can break offline features until re-registration |
| `IndexedDB` | **KEEP** | Application state, drafts, offline documents |
| `Local Storage`, `Session Storage` | **KEEP** | Login tokens and UI state - deleting logs the user out |
| `Cookies`, `Login Data`, `Web Data` | **KEEP** | Credentials and autofill |
| `blob_storage` | Delete when app closed | Transient blob spill; only valid while running |
| `*.log`, `logs/`, `xlog/` | **Delete** | Diagnostic logs; frequently the single largest item |

Deleting the *whole* profile directory logs the user out and discards local drafts.
It is never the right first move.

**Always close the application before touching its profile.** Chromium keeps SQLite
files open and partially deleting a live profile is how you corrupt it.

---

## Feishu / Lark

Desktop client data lives in `%APPDATA%\LarkShell` (a Chromium-derived layout). Chat
history itself is **server-side**, so local data is a cache of it - but login state and
local drafts are not, so do not wipe the directory wholesale.

Layout:

```
%APPDATA%\LarkShell\
  aha\users\<account-id>\
    profile_main\           <- main window Chromium profile
    profile_explorer\       <- docs/web view profile (usually the biggest)
    PartitionsV2\<feature>\ <- per-feature isolated partitions (preview, approvals, ...)
  sdk_storage\
    <account-id>\resources\ <- downloaded assets, stickers
    log\                    <- SDK logs, incl. xlog
  persistent_storage*.db    <- login state and configuration
```

| Path | Verdict | Notes |
|---|---|---|
| `aha\users\*\profile_*\Cache\Cache_Data` | **Delete** | |
| `aha\users\*\profile_*\Code Cache` | **Delete** | |
| `aha\users\*\profile_*\Service Worker\CacheStorage` | **Delete** | Often the single largest item - can exceed 1.5 GB per profile |
| `aha\users\*\PartitionsV2\*\Cache\Cache_Data`, `...\Code Cache` | **Delete** | Same rules apply inside partitions |
| `sdk_storage\log\` (contents) | **Delete** | Keep the `log` directory itself |
| `sdk_storage\<account-id>\resources` | Keep / relocate | Cached assets; regenerable but expensive to refetch |
| `persistent_storage*.db*` | **KEEP** | Login state - deleting forces a re-login |
| `IndexedDB`, `Local Storage` | **KEEP** | |

**Relocation:** the Feishu client has **no setting for the overall data path**
(Settings -> General -> File save location only controls the *download* directory).
Use a junction on `%APPDATA%\LarkShell`. Verified working: after relocation the client
retains its login and writes new data to the target drive. Suggest the user also point
the download directory at the same drive.

Reference: [Feishu help center - clearing cache](https://www.feishu.cn/hc/zh-CN/articles/399507903065)

---

## WeChat / WeCom / QQ

**Treat as user data. Do not delete, do not junction behind the user's back.**

These clients keep local message databases, received files, and images that in many
configurations exist *only* on the local machine. They are also the apps most likely
to be several gigabytes.

The right move: each of these clients has a built-in setting to change its storage
location (WeChat: Settings -> File Management; WeCom: similar). Direct the user there
and let the app migrate its own data. That keeps the app's internal bookkeeping
consistent in a way an external move does not.

Only the obvious cache subdirectories are deletable, and the payoff rarely justifies
the risk. Recommend the in-app "clear cache" function instead.

---

## Browsers

**Do not automate anything against a browser profile.** The Chromium subdirectory
table above technically applies, but the risk/reward is bad: the space is modest and
the downside is a corrupted history or password database.

If the disk is critically full, note that this is exactly the condition under which
browsers lose data, and the correct action is to free space *elsewhere*, then restart
the browser so it can reopen its databases cleanly.

If a browser's history database has already been truncated by a full disk: a restart
restores *recording*, but locally lost history is gone. If the user syncs with a
Google account, prior history remains available at
[myactivity.google.com](https://myactivity.google.com).

---

## Unreal Engine and Epic Games

| Path | Verdict | Notes |
|---|---|---|
| `%LOCALAPPDATA%\UnrealEngine\Common\DerivedDataCache` | **Delete or relocate** | DDC contents are explicitly disposable - the engine regenerates them from `.uasset` files. Relocating is better than deleting: deleting means recompiling shaders. |
| `%LOCALAPPDATA%\UnrealEngine\Common\Zen\Data` | **Relocate** | UE 5.4+ uses Zen Store as the local DDC by default |
| `%LOCALAPPDATA%\UnrealEngine\Common\Zen\Data.bak-*` | **Delete** | Abandoned Zen backups (Zen creates these after abnormal shutdowns, e.g. a full disk) |
| `%LOCALAPPDATA%\EpicGamesLauncher\Saved\webcache*` | **Delete** | Launcher CEF cache |
| `%PROGRAMDATA%\Epic\Zen\Data` | **Relocate** | Alternative Zen location on some installs |
| Project `Saved\`, `Intermediate\` | Delete per project | Rebuildable, but only with the project closed |
| Project `Content\`, `Config\`, `Source\` | **KEEP** | Actual project |

**Relocation:** stop `zenserver.exe` first, then junction
`%LOCALAPPDATA%\UnrealEngine\Common`. This covers DDC and Zen in one move and works
across all installed engine versions.

The official mechanism, if you prefer configuration over a junction, is the user
environment variable `UE-LocalDataCachePath`, or Editor Preferences ->
General -> Global -> "Global Local DDC Path". Never set `UE-SharedDataCachePath` to a
local path - that duplicates the cache.

Reference: [Epic - Using Derived Data Cache](https://dev.epicgames.com/documentation/en-us/unreal-engine/using-derived-data-cache-in-unreal-engine)

---

## NVIDIA

| Path | Verdict | Notes |
|---|---|---|
| `%LOCALAPPDATA%\NVIDIA\DXCache` | **Delete / relocate** | DirectX shader cache; games and engines rebuild it. Frequently multi-GB. |
| `%LOCALAPPDATA%\NVIDIA Corporation\NV_Cache` | **Delete** | OpenGL/Vulkan shader cache |
| `%PROGRAMDATA%\NVIDIA Corporation\Downloader\` | **Delete** | Downloaded driver installers, kept after installation |
| `%PROGRAMDATA%\NVIDIA Corporation\NVIDIA app\UpdateFramework\ota-artifacts\` | **Delete** | Driver update payloads; re-downloaded if a reinstall is needed |
| `%PROGRAMDATA%\NVIDIA Corporation\Downloader\config`, `...\registry`, `...\status` | Keep | Tiny bookkeeping |

Deleting driver packages does **not** affect the installed driver. Requires elevation.

The NVIDIA container service often holds handles inside `DXCache`, so a junction may
fail even when the contents delete fine. If the `Rename-Item` lock probe fails, clear
the contents now and create the junction after a reboot.

---

## Developer toolchains

| Path | Verdict | Mechanism |
|---|---|---|
| `~\.nuget\packages` | Relocate | `NUGET_PACKAGES` env var |
| `%LOCALAPPDATA%\ms-playwright` | Relocate | `PLAYWRIGHT_BROWSERS_PATH` env var |
| `%LOCALAPPDATA%\pip\Cache` | Delete | `pip cache purge`, or `PIP_CACHE_DIR` to relocate |
| `%APPDATA%\npm-cache` / `~\.npm` | Delete | `npm cache clean --force`, or `npm config set cache` |
| `%LOCALAPPDATA%\Yarn\Cache` | Delete | `yarn cache clean` |
| `~\.cargo\registry\cache` | Delete | Re-downloaded; `CARGO_HOME` to relocate |
| `~\.gradle\caches` | Delete | `GRADLE_USER_HOME` to relocate |
| `%LOCALAPPDATA%\electron`, `...\electron-builder\Cache` | Delete | Re-downloaded |
| `%USERPROFILE%\scoop\cache`, `%PROGRAMDATA%\chocolatey\lib-bkp` | Delete | Installer archives |
| `%LOCALAPPDATA%\JetBrains\<IDE>\caches`, `...\index` | Delete | Rebuilt on next open (slow first index) |
| `%APPDATA%\JetBrains` | **KEEP** | Settings, keymaps, plugins |
| Docker `wsl\data\ext4.vhdx` | Special | Use `docker system prune`; the VHDX does not shrink on its own |

Relocating a package cache is usually better than deleting it - the bytes are the same
either way, and relocation avoids a slow re-download.

---

## AI coding agents

Agent session transcripts accumulate quickly and are pure user history - **never
delete them**, relocate instead.

| Path | Verdict | Notes |
|---|---|---|
| `~\.claude\projects\<project>` | **Relocate** | Session transcripts and subagent logs; `--resume` depends on them |
| `~\.claude\plugins\marketplaces` | Keep | Small; re-cloneable |
| `%LOCALAPPDATA%\Temp\claude` | Delete when idle | Scratch space - not while a session is running |

A junction on the project directory preserves resume behaviour transparently. Confirm
no agent session is currently writing there first - the `Rename-Item` lock probe is a
reliable check.

---

## Windows itself

| Path | Verdict | Notes |
|---|---|---|
| `%LOCALAPPDATA%\Temp`, `C:\Windows\Temp` | Delete items older than ~7 days | Skip anything a running process owns |
| Installer unpack leftovers in `%LOCALAPPDATA%\Temp\<random>` | **Delete** | Visual Studio / MAUI / driver installers routinely abandon multi-GB unpack directories |
| `C:\Windows\SoftwareDistribution\Download` | Delete | Windows Update payloads; stop `wuauserv` first |
| `C:\$Windows.~BT`, `C:\$Windows.~WS` | Delete | Upgrade staging leftovers |
| `C:\Windows\Prefetch` | Delete (low value) | Rebuilt; minor startup penalty |
| `%LOCALAPPDATA%\CrashDumps`, `C:\Windows\LiveKernelReports`, `C:\Windows\Minidump` | Delete | Unless actively debugging a crash |
| `C:\Windows\Logs\CBS` | Delete | Servicing logs |
| `C:\Windows\WinSxS` | **NEVER delete by hand** | Only `DISM /Online /Cleanup-Image /StartComponentCleanup` |
| `C:\Windows\Installer` | **Do not delete** | MSI cache; removing it breaks repair/uninstall of installed products |
| `pagefile.sys`, `swapfile.sys`, `hiberfil.sys` | Configure, do not delete | Move the page file via System Properties; `powercfg /h off` disables hibernation |
| System Restore / Volume Shadow Copies | Ask first | Often several GB, but the user may be relying on them |
| Recycle Bin | Ask first | It is by definition full of things the user deleted but may want back |
