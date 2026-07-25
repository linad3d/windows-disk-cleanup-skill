# Windows C 盘清理技能

**清理工具删完就长回来。这个把该映射的映射掉，所以不会。**

一个 Claude Code 技能 + 独立可用的 PowerShell 工具包：先把爆满的 C 盘救回来，再用 NTFS
目录连接（junction）和环境变量，把那些**反复回涨**的目录搬到别的盘。应用还往原来的路径写，
字节落在别处。

[English](README.md) · [文档站](https://linad3d.github.io/windows-disk-cleanup-skill/)

---

## 只清理，为什么没用

删掉缓存能撑几周，然后你得再删一次。同一台真实工作站，清理后第 13 天实测：

| 当时怎么处理的 | 清理时 | 13 天后 | 增长落在哪 |
|---|---|---|---|
| **只删** — `%LOCALAPPDATA%\Temp` | 0 GB | **10.94 GB** | 回到 C 盘 |
| **只删** — NVIDIA `DXCache` | 0 GB | 0.31 GB | 回到 C 盘 |
| **做了映射** — 飞书数据目录 | 3.69 GB | **9.45 GB** | **D 盘 —— 新增 5.76 GB，C 盘一字节没占** |
| **做了映射** — AI 会话转录 | 16.18 GB | 16.19 GB | D 盘 |
| **做了映射** — NuGet + Playwright | 6.71 GB | 6.71 GB | D 盘 |

**13 天里有 11.25 GB 悄悄爬回 C 盘，约 0.87 GB/天。** 一次只删不搬的清理，大约两周就白干了。

同期做了映射的那批净增 5.32 GB，**没有一个字节进 C 盘**。这就是"映射"而不只是"删除"的全部理由：
junction 是文件系统层的透明重定向，应用打开的还是它一直用的那个路径，它根本不知道自己的数据
已经在另一个盘上了。

## 和现有工具比

| | 360安全卫士 / QQ电脑管家 | CCleaner / Windows 存储感知 | 本技能 |
|---|---|---|---|
| 一键清垃圾 | 有 | 有 | 有 —— 白名单，**默认干跑** |
| 用符号链接搬家 | 有（C盘搬家） | 无 | 有 |
| **搬什么由谁决定** | **厂商内置的软件列表** | — | **你说了算** —— 任意目录、应用、工具链 |
| 开发工具链缓存（环境变量） | 无 | 无 | 有（NuGet、npm、pip、Playwright、Cargo、Gradle、UE DDC） |
| 单个应用内逐子目录判定可删/必留 | 无 | 无 | 有 —— 30+ 应用，还能自己加 |
| 删源前字节级校验 | 未公开 | 不适用 | 有 —— 对不上就中止 |
| 常驻后台 / 广告 / 推广弹窗 | 有 | 部分 | **没有** —— 跑完就退出 |
| 卸载 | 走卸载流程 | 走卸载流程 | **删个文件夹** |
| 开源可审计 | 否 | 否 | MIT |

平心而论：360 的「C盘搬家」确实是用符号链接把已安装软件挪出 C 盘的，这部分它做得没问题。
真正的区别在于**搬的是什么**，以及**附带了什么**。

**你指哪它搬哪。** 不用等厂商把某个软件加进列表：

```powershell
.\Move-AppData.ps1 -Source "$env:APPDATA\某个没人支持的软件" -Destination "D:\AppData\SomeApp"
```

作为参照，Windows 自带的存储感知只管系统盘、**明确不碰浏览器缓存**、跳过 Teams/Spotify/Discord
这类应用的临时文件，而且默认要等磁盘快满了才动手。CCleaner 只删不搬。

## 要花多长时间

那次完整跑下来约 **25 分钟**：扫描几分钟、执行删除、再用约 11 分钟复制 29 GB 完成 5 项迁移
（SSD 到 SSD）。这是**一次性投入**。对比一下：只删的方案要你每两周重来一次，永远重来。

那一次释放了 **43.7 GB**——299 GB 系统盘从可用 19.0 GB 到 62.7 GB，零数据丢失。13 天后
复查，可用空间仍有 61.4 GB。

## 安全性

不在乎丢东西的话，腾空间很容易。这个工具是反过来做的：

- **删除只走白名单**，无法被指向任意目录——这是结构性限制，不是让你选择相信的口头承诺。
- **默认干跑**，不加 `-Execute` 什么都不删。
- **凡是人创造或积累的东西，一律搬移而非删除。**
- **删源之前先做字节级校验**：两边独立重新计数总字节与文件数，对不上就中止并还原。

真正难的不是删，而是判断一个应用的**哪个子目录**可以扔。Chromium 系桌面应用里
`Service Worker\CacheStorage` 能删，单个 profile 常超过 1.5 GB；但旁边的
`Service Worker\Database` 不能删，`Local Storage` 里还存着你的登录令牌。按文件夹一刀切的
结果就是把自己登出。技能附带一份
[应用缓存图谱](skills/windows-disk-cleanup/references/app-cache-atlas.md)，逐个列清楚这些区别。

## 安装

```powershell
git clone https://github.com/linad3d/windows-disk-cleanup-skill.git
Copy-Item -Recurse windows-disk-cleanup-skill\skills\windows-disk-cleanup "$env:USERPROFILE\.claude\skills\"
```

然后直接说人话：

> 我 C 盘只剩 8 个 G 了，帮我看看是什么占的，能清的清一下，别把聊天记录弄丢

也能被这些说法触发：`C盘满了`、`C盘爆红`、`C盘清理`、`磁盘空间不足`，以及各种搬家请求
（`把飞书缓存挪到D盘`、`让虚幻引擎的DDC放到别的盘`）。

## 直接用脚本

不需要 Claude，四个 PowerShell 脚本可以单独跑：

```powershell
# 1. 看清楚空间到底被谁吃了
.\Scan-DiskUsage.ps1 -Path C:\ -MinGB 0.3

# 2. 预览清理方案——不删任何东西
.\Invoke-SafeClean.ps1

# 3. 真正执行你选定的类别
.\Invoke-SafeClean.ps1 -Category GPU,DevTools -Execute

# 4. 搬任何东西，不管图谱里有没有列
.\Move-AppData.ps1 -Source "$env:APPDATA\SomeApp" -Destination "D:\AppData\SomeApp"

# 5. 验证 junction、环境变量，以及新数据是否真的写到了新盘
.\Test-Migration.ps1
.\Test-Migration.ps1 -Watch "D:\AppData\SomeApp"
```

## 它认识哪些应用

逐个应用给出"可删/必留"子目录清单，以及各自合适的搬家方式：

**聊天协作** — 飞书/Lark、Slack、Discord、Teams、微信、企业微信
**游戏开发** — 虚幻引擎（DDC + Zen Store）、Epic Games Launcher
**显卡** — NVIDIA DXCache / NV_Cache / 驱动安装包、AMD、Direct3D
**工具链** — NuGet、npm、pip、Yarn、Cargo、Gradle、Go、Playwright、Electron、JetBrains
**AI 助手** — Claude Code 会话转录
**Windows 本身** — Temp、Windows 更新、崩溃转储、WinSxS（以及哪些绝对不能碰）

**没列进来的照样能搬**——图谱告诉你*哪个子目录可以删*，而 `Move-AppData.ps1` 你指哪搬哪。

## 搬家方式怎么选

三种方式，按优先级：

1. **应用自带的设置**——最好，因为是应用自己迁移自己的数据。
2. **工具链官方支持的环境变量**——`NUGET_PACKAGES`、`PLAYWRIGHT_BROWSERS_PATH`、
   `UE-LocalDataCachePath` 等。
3. **NTFS 目录连接（junction）**——通用兜底，适用于前两者都没有的绝大多数应用。

junction 这条路走的是一个**任何时刻中断都安全**的顺序：

```
占用探测（原地改名）-> robocopy -> 独立重新计数字节数与文件数
                    -> 校验通过才删源
                    -> mklink /J -> 重启应用，确认新数据落在目标盘
```

删源之前，原始数据始终完好无损。`Move-AppData.ps1` 强制执行这个顺序，校验不符即中止。

## 常见问题

**清理完的空间会不会又长回来？**
做了映射的不会。上面那份 13 天实测里，被搬走的应用新产生了 5.32 GB 数据，全部落在目标盘。
同期只删没搬的部分在 C 盘回涨了 11.25 GB。这正是本技能能搬就搬、而不是只删的原因。

**会不会把聊天记录弄丢？**
不会。技能从不删除消息库、浏览器配置和草稿。对 Chromium 系应用只清 HTTP/GPU/代码缓存，
登录态原样保留。微信和企业微信则完全不碰——只会告诉你去用它们自带的存储位置设置。

**图谱里没有的应用能搬吗？**
能。`Move-AppData.ps1` 接受任意源和目标。图谱记录的是已验证应用的子目录安全性；搬家机制本身
是通用的。

**junction 安全吗？应用会不会出问题？**
junction 是文件系统层的重定向，在应用层之下解析，所以应用把它当真实目录用。要求两端都是
NTFS 且在同一台机器——别指向网络共享或可能开机时不在的移动硬盘。

**删掉虚幻引擎的 DDC 会不会毁了项目？**
不会。Epic 官方文档明确写着 DDC 内容是可丢弃的，会从 `.uasset` 重新生成。不过搬移比删除
更划算，因为删了意味着重新编译着色器。

**robocopy 返回了 1，是失败了吗？**
不是。robocopy 的退出码是位域：**小于 8 都算成功**（`1` 表示有文件被复制）。用 `$?` 或
`$LASTEXITCODE -ne 0` 判断，会把一次完美的复制报成失败。

**为什么我的脚本报一堆莫名其妙的 null 错误？**
Windows PowerShell 5.1 会把不带 BOM 的 UTF-8 文件当 ANSI 读。注释里的中文会打乱字节流，
**吞掉相邻的语句**——变量静默变成 `$null`，脚本跑了一半却不报错。所以辅助 `.ps1` 一律写成
纯 ASCII，或存成带 BOM 的 UTF-8。详见
[windows-pitfalls.md](skills/windows-disk-cleanup/references/windows-pitfalls.md)。

**设了环境变量，IDE 却还在用老的包缓存。**
在变量设置之前就已启动的进程继承的是旧环境。重启 IDE 或终端即可。

**为什么要趁早清，而不是等 C 盘真满了再说？**
因为 Windows 分区写到零字节时不会体面地报错，**它会静默损坏当时正在写入的东西**。催生这个
项目的那次事故里，写满的 C 盘把 Chrome 的 `History` 库截断成了空壳，而 Chrome 不重启就一直
不再记录任何历史——几天后才被发现。

## 文档

| 文件 | 内容 |
|---|---|
| [SKILL.md](skills/windows-disk-cleanup/SKILL.md) | Claude 遵循的工作流 |
| [app-cache-atlas.md](skills/windows-disk-cleanup/references/app-cache-atlas.md) | 逐应用：哪些能删、哪些必须留 |
| [relocation-methods.md](skills/windows-disk-cleanup/references/relocation-methods.md) | 应用设置 vs 环境变量 vs junction |
| [windows-pitfalls.md](skills/windows-disk-cleanup/references/windows-pitfalls.md) | PowerShell、编码、robocopy、文件占用的坑 |
| [case-study.md](skills/windows-disk-cleanup/references/case-study.md) | 完整的 43.7 GB 实战记录，以及 13 天后的复查数据 |
| [evals/README.md](skills/windows-disk-cleanup/evals/README.md) | 触发测试：19 条计分查询全对 |

## 环境要求

Windows 10/11 · PowerShell 5.1+ · 源和目标都是 NTFS · `mklink`、`C:\ProgramData`、
`C:\Windows\Temp` 需要管理员权限。
[Claude Code](https://claude.com/claude-code) 是可选的——脚本可以独立运行。

## 参与贡献

最有价值的贡献是往应用缓存图谱里加条目：应用名、哪些子目录可再生、哪些存着状态，以及你是
怎么验证的。**只收第一手结论**——这张表里一个没验证过的猜测，就是别人丢登录态的原因。

## 许可

MIT，见 [LICENSE](LICENSE)。
