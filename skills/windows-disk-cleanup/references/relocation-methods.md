# Relocation Methods

How to move a directory off the system drive so that the owning application never
notices. Three mechanisms, in order of preference.

## Choosing a mechanism

| Mechanism | Use when | Pros | Cons |
|---|---|---|---|
| **App setting** | The app exposes a data/storage path setting | The app migrates its own data and keeps internal bookkeeping consistent | Only some apps offer it |
| **Environment variable** | A toolchain documents one | Declarative, survives reinstalls, no filesystem trickery | Only affects newly started processes; per-user unless set machine-wide |
| **NTFS junction** | Neither of the above exists (the common case) | Works for anything, app needs no support | Same-machine/NTFS only; invisible to the user later |

Prefer the highest option that is actually available. A junction is the universal
fallback, not the default choice.

---

## 1. Application settings

Always try this first for applications that own user data.

| Application | Where |
|---|---|
| WeChat | Settings -> File Management -> storage location |
| WeCom | Settings -> General -> file storage location |
| Steam | Steam -> Settings -> Storage -> add library folder |
| JianYing / CapCut | Settings -> Draft location |
| Feishu / Lark | Settings -> General -> File save location (**downloads only** - not the cache) |
| OneDrive / Dropbox | Unlink, then re-link choosing a new local folder |
| Docker Desktop | Settings -> Resources -> Disk image location |
| Visual Studio | Tools -> Options -> Projects and Solutions -> Locations |

Note the Feishu caveat: the setting exists but only governs downloads. The bulk of the
data still sits in `%APPDATA%\LarkShell` and needs a junction.

---

## 2. Environment variables

Set at user scope and the value persists across reboots and reinstalls:

```powershell
[Environment]::SetEnvironmentVariable('NUGET_PACKAGES', 'D:\PackageCaches\nuget\packages', 'User')
```

`setx` does the same thing but truncates values over 1024 characters, so prefer the
.NET call.

| Variable | Controls | Default |
|---|---|---|
| `NUGET_PACKAGES` | NuGet global packages | `~\.nuget\packages` |
| `PLAYWRIGHT_BROWSERS_PATH` | Playwright browser binaries | `%LOCALAPPDATA%\ms-playwright` |
| `PIP_CACHE_DIR` | pip wheel cache | `%LOCALAPPDATA%\pip\Cache` |
| `npm_config_cache` | npm cache | `%APPDATA%\npm-cache` |
| `CARGO_HOME` | Rust toolchain + registry | `~\.cargo` |
| `GRADLE_USER_HOME` | Gradle caches | `~\.gradle` |
| `GOPATH`, `GOMODCACHE` | Go modules | `~\go` |
| `UE-LocalDataCachePath` | Unreal local DDC | `%LOCALAPPDATA%\UnrealEngine\Common\DerivedDataCache` |
| `DOTNET_CLI_HOME` | .NET CLI state | `~` |
| `HF_HOME` | Hugging Face model cache | `~\.cache\huggingface` |
| `TORCH_HOME` | PyTorch model cache | `~\.cache\torch` |

**The gotcha:** already-running processes inherited the old environment. IDEs,
terminals, and background services must be restarted before they see the new value.
Say this explicitly when reporting - otherwise the user "proves" it did not work by
checking in an already-open terminal.

Move the existing contents too, or the tool re-downloads everything.

---

## 3. NTFS directory junctions

A junction is a filesystem-level redirect. Unlike a shortcut, applications open it as
if it were a real directory - no app support required.

```cmd
mklink /J "C:\Users\<user>\AppData\Roaming\SomeApp" "D:\AppData\SomeApp"
```

PowerShell equivalent:

```powershell
New-Item -ItemType Junction -Path $original -Target $destination
```

### The mandatory sequence

```
1. Close the application. Verify with the Rename-Item lock probe.
2. robocopy <src> <dst> /E /COPY:DAT /DCOPY:DAT /R:2 /W:2
3. VERIFY: recount total bytes AND file count on both sides. Require exact equality.
4. Delete the source (only now).
5. mklink /J <original path> <destination>
6. Start the app, confirm new writes land on the destination.
```

Steps 3 and 4 are the whole point. Until the source is deleted the original data is
still fully intact, so the operation is safe to abandon at any earlier moment. Trusting
robocopy's own summary instead of recounting is the failure mode this sequence exists
to prevent.

`scripts/Move-AppData.ps1` implements exactly this and refuses to continue on a
mismatch.

### Constraints

- **Same machine, NTFS on both sides.** Not network shares, not FAT32/exFAT, not a
  removable drive that might be absent at boot.
- **Never junction anything the OS needs before all volumes mount** - no
  `C:\Windows`, no `C:\Program Files`, no user profile root. Application data
  directories under `AppData` are fine.
- Creating a junction requires elevation on most systems.
- Backup tools may follow junctions and either duplicate or skip the content. Check
  whether your backup product treats reparse points as data or as links.
- The redirect is invisible in Explorer beyond a small overlay. Keep a record of what
  was moved where - `Test-Migration.ps1` can enumerate them, and the case study
  suggests leaving a note in the destination root.

### Junction vs symbolic link vs hard link

| Type | Scope | Needs admin | Use for this task |
|---|---|---|---|
| Junction (`/J`) | Directories, local volumes | Usually yes | **Yes - the right tool** |
| Directory symlink (`/D`) | Directories, can cross to UNC | Yes (or Developer Mode) | Only if you need a network target |
| Hard link (`/H`) | Single files, same volume only | No | Not applicable |

Junctions are resolved by the filesystem below the application layer, which is why
even apps that dislike symlinks accept them.

### Verifying a junction

```powershell
(Get-Item $path -Force).Target          # -> destination path
(Get-Item $path -Force).Attributes      # -> Directory, ReparsePoint
```

`cmd /c dir` shows `<JUNCTION>` in the listing. Note that `.Target` returns a
collection; render it with `-join` or index it rather than string-concatenating, or
you will print `System.String[]`.

### Undoing one

```powershell
# Removes the junction only - the target contents are untouched
(Get-Item $path -Force).Delete()
```

Do not use `Remove-Item -Recurse` on a junction from an older PowerShell without
checking behaviour; the safe move is `.Delete()` on the DirectoryInfo, which removes
the reparse point itself. Then move the data back if desired.
