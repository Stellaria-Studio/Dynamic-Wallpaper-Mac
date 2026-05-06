# 动态壁纸引擎 — 架构文档

## 1. 项目概述

macOS 动态壁纸应用，将视频文件作为桌面壁纸播放。支持多屏幕、播放列表、自适应性能管理、独立音量调节等功能。

**核心矛盾**：AVFoundation 在视频切换时 `replaceCurrentItem(with:)` 导致的 use-after-free crash（EXC_BAD_ACCESS）与切换黑屏之间的取舍。

---

## 2. 架构总览

采用**双进程架构**，通过 JSON-over-Pipe IPC 通信：

```
VideoWallpaper.app (主应用)                     WallpaperPlayer.app (Helper)
┌──────────────────────────────┐               ┌──────────────────────────────┐
│ AppDelegate                  │               │ PlayerEngine                 │
│  ├─ PlayerProxy (IPC 代理)    │──stdin/stdout──│  ├─ AVQueuePlayer ×1         │
│  ├─ ControlWin (控制面板)     │    JSON 行     │  ├─ AVPlayerLooper           │
│  ├─ PlaylistManager          │               │  ├─ AVPlayerItem 保活列表     │
│  ├─ AdaptivePerformanceMgr   │               │  └─ NSWindow × N (每屏一个)   │
│  └─ FolderWatcher            │               └──────────────────────────────┘
│ 无 AVFoundation              │               纯 AVFoundation, 无 UI
└──────────────────────────────┘               LSUIElement=1 (无 Dock 图标)
```

**设计意图**：将 AVFoundation 隔离到独立进程中。即使 helper 进程 crash，主应用 UI 不受影响，helper 自动重启并恢复状态。

---

## 3. 进程间通信 (IPC)

### 3.1 通信方式

`Process` 的 stdin/stdout 管道，每行一条 JSON：

```
→ Helper stdin:  {"cmd":"switchVideo","url":"/path/to/video.mp4","quality":"1080p"}
← Helper stdout: {"event":"playing","url":"/path/to/video.mp4","mb":28.3}
← Helper stdout: {"event":"status","muted":true,"paused":false,"volume":1.0,"mb":28.3}
```

stdin 通过 `FileHandle.readabilityHandler` 异步读取，stdout 同样异步读取并逐行解析。

### 3.2 命令列表 (主应用 → Helper)

| 命令 | 参数 | 说明 |
|------|------|------|
| `start` | url, quality, muted, singleMode | 完全初始化（销毁旧→建窗口→建播放器→播放） |
| `switchVideo` | url, quality? | 切换视频（replaceCurrentItem + 旧 item 保活 3s） |
| `setPaused` | value | 暂停/继续 |
| `setPerformancePaused` | value | 性能降级时暂停 |
| `forcePause` | — | 强制暂停（系统休眠时） |
| `resumeIfNotPaused` | — | 恢复（未手动暂停时） |
| `setHidden` | value | 隐藏/显示壁纸窗口 |
| `toggleHidden` | — | 切换隐藏 |
| `setMuted` | value | 静音/取消静音 |
| `toggleMute` | — | 切换静音 |
| `setVolume` | value (0.0~1.0) | 独立音量 |
| `setSingleMode` | value | 单曲循环模式 |
| `setQuality` | value | 画质 |
| `cleanup` | — | 释放所有资源 |
| `queryState` | — | 查询状态 |

### 3.3 事件列表 (Helper → 主应用)

| 事件 | 数据 | 说明 |
|------|------|------|
| `ready` | mb | Helper 启动完成（启动后 0.1s 发送） |
| `playing` | url, mb | 开始播放某视频 |
| `status` | paused, muted, hidden, volume, mb | 状态更新 |
| `videoEnded` | mb | 视频播放完毕 |
| `muted` | value | 静音变更 |
| `hidden` | value | 隐藏变更 |
| `volume` | value | 音量变更 |
| `error` | message | 错误 |

每个事件都包含 `mb`（当前内存占用 MB），用于主应用监控内存增长。

### 3.4 崩溃自动恢复

Helper 退出 → `Process.terminationHandler` → `PlayerProxy.onHelperExit()`:
1. 清理 pipe handler
2. 设置 `needsRestore = true`
3. 0.5 秒后自动重启 helper
4. Helper 重启后发送 `ready` 事件
5. PlayerProxy 检测 `needsRestore && currentURL != nil` → 发送 `start` 命令 + 恢复所有状态（静音、隐藏、暂停、音量）

---

## 4. 核心模块

### 4.1 WallpaperPlayer (Helper 进程)

**文件**: `WallpaperPlayer/main.swift` (439 行)

一个 accessory 进程，通过 stdin/stdout JSON 通信，使用 `NSApplication` 事件循环。

#### PlayerEngine

核心播放引擎，使用**双 AVQueuePlayer 预加载（方案 D）**：

```
PlayerEngine (双播放器)
├── playerA / playerB: AVQueuePlayer? ← 两个独立播放器，一显一藏
├── looperA / looperB: AVPlayerLooper? ← 各自单曲循环
├── activeIsA: Bool                    ← 标记哪个是当前显示
├── currentPlayer: AVQueuePlayer?      ← 计算属性: activeIsA ? playerA : playerB
├── standbyPlayer: AVQueuePlayer?      ← 计算属性: activeIsA ? playerB : playerA
├── retiredPlayers: [AVPlayer]         ← 退役播放器保活 3 秒，防 use-after-free
├── windows: [NSWindow]                ← 每个 NSScreen 一个
├── playerViews: [VideoPlayerView]     ← 每个 NSWindow 一个
├── endObserver                        ← AVPlayerItemDidPlayToEndTime 通知
├── preloadWorkItem: DispatchWorkItem?  ← 待取消的预加载任务
├── switchGeneration: Int              ← generation 计数器防陈旧回调
└── 状态属性: isUserPaused, isMuted, volume, quality, singleMode
```

**核心方法**:

`start(url:quality:muted:singleMode:)` — 完全初始化:
1. `destroyBothPlayers()` 清理旧的
2. 检查 `playerViews.isEmpty` → 调用 `createWindowsForAllScreens()`
3. 创建 playerA + AVPlayerLooper（单曲）或 AVPlayerItem + endObserver（顺序）
4. `attachPlayerToAllWindows(playerA)` → 播放

`switchVideo(url:quality:)` — 视频切换（预加载）:
1. 首次调用（无播放器）: 直接创建 playerA 播放
2. 后续调用:
   - `preloadWorkItem?.cancel()` 取消上次预加载
   - `switchGeneration += 1` 递增 generation
   - DispatchWorkItem → `preloadAndSwitch(gen:)`

`preloadAndSwitch(gen:)` — 创建备用播放器:
1. 创建 `AVQueuePlayer(items: [newItem])`（非空队列，状态机可靠）
2. 存入 standby 槽位（清理旧 standby looper + player）
3. 立即同步 `isMuted` / `volume`
4. 调用 `waitForItemThenSwitch(player, gen, retries: 50)`

`waitForItemThenSwitch(_:gen:retries:)` — 轮询就绪:
1. generation 守卫 → 陈旧回调丢弃
2. `currentItem?.status == .readyToPlay` → 执行 `performSwitch`
3. retries > 0 → 100ms 后重试
4. 超时 → 降级执行 `performSwitch` + 错误日志

`performSwitch(newPlayer:gen:)` — 零黑屏交换:
1. 销毁旧 endObserver
2. 销毁旧 looperA + looperB（全部清理）
3. 保存 `oldPlayer = currentPlayer`
4. `activeIsA.toggle()` → newPlayer 成为 current
5. 为 newPlayer 设置 looper / endObserver（此时 oldPlayer 仍在屏幕可见）
6. `attachPlayerToAllWindows(newPlayer)` → **零黑屏交换**
7. 同步 mute / volume / rate → `play()`
8. `oldPlayer?.pause()` → 加入退休队列（3 秒后释放）

**关键设计**:
- 双播放器 + layer 指针交换消除黑屏：新播放器预加载就绪后直接换 layer
- standby 使用 `AVQueuePlayer(items:)` 创建，`currentItem` 立即可用
- 检查 `currentItem?.status` 而非 `player.status`，确保真实解码就绪
- Generation 计数器 + `preloadWorkItem.cancel()` 双重防止陈旧回调
- 退役播放器 3 秒保活 + 防重复加入
- 不使用 `preroll(atRate:)`，状态切换更可靠

#### VideoPlayerView

每个屏幕对应: `NSWindow(desktopIconWindow - 1)` → `NSView` → `AVPlayerLayer`
```
layer 层级: Desktop Icons > 壁纸窗口 > Desktop Background
```
`attach(player:)` / `detach()` 切换 AVPlayerLayer 绑定的播放器。

#### CommandHandler

解析 stdin JSON 行，dispatch 到 PlayerEngine 对应方法。buffer 处理 TCP 式粘包。

#### writeEvent()

全局函数，向 stdout 写 JSON 事件行，自动附加当前内存占用 `mb` 字段。

---

### 4.2 PlayerProxy (IPC 代理)

**文件**: `WallpaperApp/PlayerProxy.swift` (277 行)

主应用侧的代理层，主应用其他组件通过它操作壁纸。

**关键功能**:

- **Helper 查找**: 打包路径 → 同级开发路径 → 源码目录路径
- **进程管理**: `Process()` + stdin/stdout Pipe
- **状态缓存**: 从 helper 事件同步 `isUserPaused`, `isMuted`, `isHidden`, `volume` 等
- **崩溃恢复**: `needsRestore` 标志位，仅 crash 后重启时发送恢复命令（初始启动不恢复）
- **命令发送**: `sendCommand(_:)` 将 `[String: Any]` JSON 序列化后写入 stdin pipe

---

### 4.3 VideoWallpaper (主应用)

**文件**: `WallpaperApp/main.swift` (535 行)

#### AppDelegate

应用入口，组合所有组件：

```
AppDelegate
├── wallpaper: PlayerProxy           ← 壁纸播放代理
├── playlist: PlaylistManager        ← 播放列表（单曲/顺序/随机）
├── watcher: FolderWatcher           ← kqueue 监听视频文件夹变化
├── controlWin: ControlWin?          ← 控制面板 NSPanel
├── adaptiveManager: AdaptivePerformanceManager?
├── statusItem: NSStatusItem?        ← 菜单栏图标
├── videoQuality: VideoQuality       ← 当前画质
├── converted: [URL: URL]            ← 转码文件缓存
└── testController: TestController?  ← 测试模式
```

**启动流程**:
1. PlayerProxy.init() → launchHelper()
2. Helper 启动（异步），0.1s 后发送 ready
3. 扫描 `壁纸素材/` 目录 → 设置 playlist → startCurrent() → `wallpaper.switchVideo(url:)`
4. 设置 FolderWatcher 监听文件变化
5. 显示 ControlWin

**视频播放流程**:
```
playNext() → switchToVideo(at:) → play(url:quality:) async
    → processVideo(url:quality:)     // 1080p 转码（如需）
    → wallpaper.switchVideo(url:)    // PlayerProxy → sendCommand → Helper
    → Helper: PlayerEngine.switchVideo()
```

#### ControlWin

`NSPanel` + `nonactivatingPanel`，右上角浮动面板：

- **折叠** (68px): 视频名称 + 音频/文件夹按钮
- **展开** (240px): ◀ ⏸ ▶ + 音量滑块 + 模式/画质选择 + 播放列表 + 隐藏/退出

按钮 target 设为 AppDelegate 的 `@objc` 方法。

#### PlaylistManager

三种模式: single / sequential / shuffled。禁用视频持久化到 UserDefaults。

---

### 4.4 AdaptivePerformanceManager

**文件**: `WallpaperApp/AdaptiveManager.swift` + `SystemMonitor.swift`

| 监控器 | 触发 | 行为 |
|--------|------|------|
| PowerMonitor | 电池供电 | 降画质到 1080p |
| ThermalMonitor | 温度 serious/critical | setPerformancePaused(true) |
| SleepWakeHandler | 系统休眠 | forcePause()，唤醒后 resumeIfNotPaused() |
| FullScreenDetector | 全屏应用 | setPerformancePaused(true) |

---

### 4.5 测试工具

**TestController** (`WallpaperApp/Tester.swift`): 内建测试模式，`--test` 启动。

| 场景 | 间隔 | 操作 |
|------|------|------|
| `rapid` | 3s | playNext()，每 5 次换画质 |
| `mixed` | 5s | 随机切换视频/画质/静音/模式/禁用 |
| `long` | 30s | 切换视频 + 峰值内存记录 |
| `stress` | 1s | 快速切换 + 画质/模式循环 |

日志位置: `~/Library/Logs/wallpaper_test/test_YYYYMMDD_HHmmss.log`

**WallpaperTestApp**: 独立 GUI 测试工具。
**run_test.sh**: Shell 脚本，崩溃自动重启。

---

## 5. 视频切换方案演进（核心问题 — 当前方案5.4）

### 5.1 方案 A：replaceCurrentItem（原始版）

```swift
player?.replaceCurrentItem(with: AVPlayerItem(asset: ...))
```
- ✅ **无黑屏**: 播放器一直存活
- ❌ **crash**: AVFoundation 异步释放旧 item 时访问已释放内存 → `EXC_BAD_ACCESS`（`0xa1a1a1a1` / `0xa3a3a3a3`）

### 5.2 方案 B：销毁 + 重建

```swift
destroyPlayer()  // 等 50ms → buildPlayer(url:)
```
- ✅ **无 crash**: 新旧播放器完全隔离
- ❌ **黑屏**: 销毁到重建之间 layer 无内容

### 5.3 方案 C：replaceCurrentItem + 旧 item 保活 3s（旧方案，已替换）

```swift
retainedItems.append(oldItem)
DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
    retainedItems.removeAll { $0 === oldItem }
}
player?.replaceCurrentItem(with: newItem)
player?.play()
```
- ✅ **无 crash**: 旧 item 保留 3 秒，AVFoundation 内部引用走完再释放
- ⚠️ **仍有黑屏**: `replaceCurrentItem` 执行时有短暂画面切换间隙（视频解码器切换、首帧解码）
- ✅ **稳定可靠**: 经压力测试验证（120 次快速切换无崩溃，内存 30MB 稳定）

### 5.4 方案 D：双播放器预加载（当前方案 ✅）

```
切换时 → 创建第二个 AVPlayer，后台缓冲 → 就绪后 layer 指针交换 → 销毁旧播放器
```
- ✅ **零黑屏**: 新播放器预加载就绪后才交换，旧播放器保持显示最后一帧直到切换
- ✅ **无 crash**: 不用 `replaceCurrentItem`，新旧播放器完全隔离，退役播放器保活 3 秒
- ✅ **稳定可靠**: 60 次 stress 测试通过，内存 ~30-35MB 无泄漏

**关键改进（相比上次失败实现）**:

| 问题 | 上次 | 本次 |
|------|------|------|
| 创建方式 | `AVQueuePlayer()` + `replaceCurrentItem` | `AVQueuePlayer(items:)` 带 item 创建 |
| 就绪检查 | `player.status` | `currentItem?.status` |
| 退役逻辑 | 误退役新播放器 | `oldPlayer = currentPlayer` → toggle |
| Preroll | `preroll(atRate:)` | 等待 5 秒就绪，超时降级 |
| Gen 守卫 | 无 | `switchGeneration` 全局计数器 |

---

## 6. 关键技术细节

### 6.1 窗口层级
```swift
w.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
```
壁纸窗口位于桌面图标**下方**、桌面背景**上方**。

### 6.2 多屏幕
PlayerEngine 对每个 NSScreen 创建一个 NSWindow + VideoPlayerView。
`screensChanged()` 监听 `didChangeScreenParametersNotification`，重建所有窗口。

### 6.3 Autorelease Pool
`destroyPlayer()` / `cleanup()` 中使用 `autoreleasepool {}` 显式管理，防止 AVFoundation 对象积压。

### 6.4 视频转码
`processVideo()` 在 `--high` 画质下自动将 >1080p 视频转码为 1080p MP4（`AVAssetExportPreset1920x1080`），临时文件缓存到 `converted` 字典。

---

## 7. 构建

```bash
# 编译 Helper（产物: WallpaperPlayer.app）
bash WallpaperPlayer/build.sh

# 编译主应用（自动包含 Helper 打包）
bash WallpaperApp/build.sh
# 产物: VideoWallpaper.app/Contents/Resources/WallpaperPlayer.app
```

文件位置: `.app` 产物在 `004玩具/` 目录下，与 `壁纸素材/` 同级。

---

## 8. 测试

```bash
# 内建测试
./VideoWallpaper.app/Contents/MacOS/VideoWallpaper --test --scenario rapid --interval 3 --duration 1

# Shell 测试脚本（崩溃自动重启）
bash WallpaperTester/run_test.sh rapid 1 1800

# 内存监控: 辅助进程 mem: 事件中的 mb 字段
```

---

## 9. 文件清单

| 文件 | 行数 | 说明 |
|------|------|------|
| `WallpaperPlayer/main.swift` | 440 | Helper: 双播放器预加载 + IPC 命令处理 |
| `WallpaperPlayer/build.sh` | — | Helper 编译脚本 |
| `WallpaperPlayer/Info.plist` | — | LSUIElement=1 隐藏 Dock 图标 |
| `WallpaperApp/main.swift` | 535 | 主应用: UI + 播放列表 + 控制面板 |
| `WallpaperApp/PlayerProxy.swift` | 277 | IPC 代理: 进程管理 + 命令/事件 |
| `WallpaperApp/AdaptiveManager.swift` | 90 | 自适应性能管理 |
| `WallpaperApp/SystemMonitor.swift` | 174 | 电源/温度/休眠/全屏监控 |
| `WallpaperApp/Tester.swift` | 269 | 内建测试控制器 |
| `WallpaperApp/build.sh` | — | 主应用编译脚本 |
| `WallpaperApp/Info.plist` | — | 应用配置 |
| `WallpaperTestApp/main.swift` | 329 | GUI 测试工具 |
| `WallpaperTester/run_test.sh` | — | Shell 测试脚本 |

---

## 10. 已知问题

1. **~~黑屏~~ 已解决**: 方案 D 双播放器预加载实现，零黑屏切换
2. **~~use-after-free crash~~ 已解决**: 退役播放器保活 + 双播放器隔离（不用 `replaceCurrentItem`）
3. **音量持久化**: 未保存到 UserDefaults，重启恢复为 1.0
4. **快速连续切换**: 极端快速切换（<100ms 间隔）的边界行为未充分验证
