# Windows C 盘清理技能

**一个 Claude Code 技能：把爆满的 Windows C 盘救回来，且不丢任何用户数据。**
它先扫清楚空间到底被什么吃掉，只删可再生的缓存，其余的用 NTFS 目录连接（junction）
和环境变量搬到别的盘——所以腾出来的空间不会再涨回去。

[English](README.md) · [文档站](https://linad3d.github.io/windows-disk-cleanup-skill/)

> 出自一次真实救援：299 GB 系统盘**单次释放 43.7 GB**（可用 19.0 GB → 62.7 GB），
> 零数据丢失。[案例记录](skills/windows-disk-cleanup/references/case-study.md)
> 里每个数字都是实测值，不是估算。

---

## 为什么需要它

Windows 分区写到零字节时不会体面地报错，**它会静默损坏当时正在写入的东西。**
在催生这个技能的那次事故里，写满的 C 盘把 Chrome 的 `History` SQLite 库截断成了空壳，
而 Chrome 不重启就一直不再记录任何历史——几天后才被发现。

多数清理工具比拼的是删得多。这个工具的第一目标是**不毁掉任何东西**，第二目标是让空间
不再回涨：

- **只删白名单内**已知可再生的缓存路径。它无法被指向任意目录——这是结构性限制，不是口头约定。
- **默认干跑**。不加 `-Execute` 就不会删任何东西。
- 凡是人创造或积累的东西，**一律搬移而非删除**。
- **删源之前先做字节级校验**。重新计数对不上就中止并还原，绝不删。

## 和别的工具差在哪

网上的教程大多是"清空 %TEMP%、清一下回收站"。真正难的是判断一个应用的**哪个子目录**
可以扔——空间恰恰堆在那里，数据丢失也恰恰发生在那里。

| | 常见清理工具 | 本技能 |
|---|---|---|
| 粒度 | 整个文件夹 | 精确到每个应用的每个子目录 |
| 登录态 | 经常被一起清掉 | 明确保留 |
| 安全机制 | "确定要删吗？" | 白名单 + 干跑 + 字节校验 |
| 持久性 | 过阵子又满 | junction 与环境变量让它不再回到 C 盘 |

举个具体例子：Chromium 系桌面应用里，`Service Worker\CacheStorage` 可以删，单个 profile
经常超过 1.5 GB；但它旁边的 `Service Worker\Database` 不能删，`Local Storage` 里存着你的
登录令牌。按文件夹一刀切的结果就是把自己登出。技能里附了一份
[应用缓存图谱](skills/windows-disk-cleanup/references/app-cache-atlas.md)，逐个列清楚这些区别。

## 安装

```powershell
git clone https://github.com/linad3d/windows-disk-cleanup-skill.git
Copy-Item -Recurse windows-disk-cleanup-skill\skills\windows-disk-cleanup "$env:USERPROFILE\.claude\skills\"
```

然后直接跟 Claude Code 说人话就行：

> 我 C 盘只剩 8 个 G 了，帮我看看是什么占的，能清的清一下，别把聊天记录弄丢

也能被这些说法触发：`C盘满了`、`C盘爆红`、`C盘清理`、`磁盘空间不足`，以及各种搬家请求
（`把飞书缓存挪到D盘`、`让虚幻引擎的DDC放到别的盘`）。

## 直接用脚本

四个 PowerShell 脚本不依赖 Claude，可以单独跑：

```powershell
# 1. 看清楚空间到底被谁吃了
.\Scan-DiskUsage.ps1 -Path C:\ -MinGB 0.3

# 2. 预览清理方案——不删任何东西
.\Invoke-SafeClean.ps1

# 3. 真正执行你选定的类别
.\Invoke-SafeClean.ps1 -Category GPU,DevTools -Execute

# 4. 把舍不得删的东西搬走
.\Move-AppData.ps1 -Source "$env:APPDATA\SomeApp" -Destination "D:\AppData\SomeApp"

# 5. 验证 junction、环境变量，以及新数据是否真的写到了新盘
.\Test-Migration.ps1
.\Test-Migration.ps1 -Watch "D:\AppData\SomeApp"
```

## 覆盖的应用

逐个应用给出"可删/必留"子目录清单，以及各自合适的搬家方式：

**聊天协作** — 飞书/Lark、Slack、Discord、Teams、微信、企业微信
**游戏开发** — 虚幻引擎（DDC + Zen Store）、Epic Games Launcher
**显卡** — NVIDIA DXCache / NV_Cache / 驱动安装包、AMD、Direct3D
**工具链** — NuGet、npm、pip、Yarn、Cargo、Gradle、Go、Playwright、Electron、JetBrains
**AI 助手** — Claude Code 会话转录
**Windows 本身** — Temp、Windows 更新、崩溃转储、WinSxS（以及哪些绝对不能碰）

## 搬家怎么做

三种方式，按优先级：

1. **应用自带的设置**——最好，因为是应用自己迁移自己的数据。
2. **工具链官方支持的环境变量**——`NUGET_PACKAGES`、`PLAYWRIGHT_BROWSERS_PATH`、
   `UE-LocalDataCachePath` 等。
3. **NTFS 目录连接（junction）**——通用兜底。应用会把 junction 当成真实目录打开，无需应用支持。

junction 这条路走的是一个**任何时刻中断都安全**的顺序：

```
占用探测（原地改名）-> robocopy -> 独立重新计数字节数与文件数
                    -> 校验通过才删源
                    -> mklink /J -> 重启应用，确认新数据落在目标盘
```

删源之前，原始数据始终完好无损。`Move-AppData.ps1` 强制执行这个顺序，校验不符即中止。

## 常见问题

**会不会把聊天记录弄丢？**
不会。技能从不删除消息库、浏览器配置和草稿。对 Chromium 系应用只清 HTTP/GPU/代码缓存，
登录态原样保留。微信和企业微信则完全不碰——只会告诉你去用它们自带的存储位置设置。

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
纯 ASCII，或存成带 BOM 的 UTF-8。这个坑是实打实调出来的，详见
[windows-pitfalls.md](skills/windows-disk-cleanup/references/windows-pitfalls.md)。

**设了环境变量，IDE 却还在用老的包缓存。**
在变量设置之前就已启动的进程继承的是旧环境。重启 IDE 或终端即可。

## 文档

| 文件 | 内容 |
|---|---|
| [SKILL.md](skills/windows-disk-cleanup/SKILL.md) | Claude 遵循的工作流 |
| [app-cache-atlas.md](skills/windows-disk-cleanup/references/app-cache-atlas.md) | 逐应用：哪些能删、哪些必须留 |
| [relocation-methods.md](skills/windows-disk-cleanup/references/relocation-methods.md) | 应用设置 vs 环境变量 vs junction |
| [windows-pitfalls.md](skills/windows-disk-cleanup/references/windows-pitfalls.md) | PowerShell、编码、robocopy、文件占用的坑 |
| [case-study.md](skills/windows-disk-cleanup/references/case-study.md) | 完整的 43.7 GB 实战记录与真实数字 |

## 环境要求

Windows 10/11 · PowerShell 5.1+ · 源和目标都是 NTFS · `mklink`、`C:\ProgramData`、
`C:\Windows\Temp` 需要管理员权限。
[Claude Code](https://claude.com/claude-code) 是可选的——脚本可以独立运行。

## 参与贡献

最有价值的贡献是往应用缓存图谱里加条目：应用名、哪些子目录可再生、哪些存着状态，以及你是
怎么验证的。**只收第一手结论**——这张表里一个没验证过的猜测，就是别人丢登录态的原因。

## 许可

MIT，见 [LICENSE](LICENSE)。
