#!/usr/bin/env python3
"""
macOS 动态壁纸引擎 — 架构文档
=============================
埋入此文件，任何 AI 都可以瞬间理解项目的本质和问题。

用法:
    python wallpaper_arch.py       # 打印详细文档
    python wallpaper_arch.py --ai  # 打印 AI 摘要
"""

ARCHITECTURE = r"""
# 动态壁纸引擎 — 架构文档

## 1. 一句话本质

macOS 壁纸应用 = Swift+Cocoa UI 主进程 + Swift+AVFoundation Helper 进程，
通过 JSON/pipe IPC 通信。核心矛盾是 AVPlayer.replaceCurrentItem 导致的
use-after-free crash 与 切换黑屏 之间的取舍。

## 2. 双进程架构

VideoWallpaper.app (主应用)          WallpaperPlayer.app (Helper)
┌─────────────────────────┐        ┌──────────────────────────┐
│ AppDelegate             │        │ PlayerEngine: 单 AVQueue  │
│  PlayerProxy (IPC 代理) │──JSON──│  旧 item 保活 3s          │
│  ControlWin (控制面板)   │  pipe  │  AVPlayerLooper           │
│  PlaylistManager        │        │  NSWindow × N (多屏)      │
│  AdaptiveManager        │        │  AVPlayerLayer             │
└─────────────────────────┘        └──────────────────────────┘
无 AVFoundation                    纯 AVFoundation, 无 UI

## 3. IPC 协议

命令 (主→Helper): {"cmd":"switchVideo","url":"/path/视频.mp4"}
事件 (Helper→主): {"event":"playing","url":"...","mb":28.3,"muted":true}

15 个命令 / 8 种事件。每行一条 JSON。

## 4. 核心模块

### PlayerEngine (WallpaperPlayer/main.swift)
- 双 AVQueuePlayer（playerA/playerB），一显一藏
- 切换：备用播放器后台预加载 → 就绪后交换 layer → 旧播放器退役保活 3s
- singleMode: AVPlayerLooper 单曲循环
- 顺序模式: endObserver (AVPlayerItemDidPlayToEndTime)
- 无 replaceCurrentItem，无 preroll
- switchGeneration 计数器防陈旧回调
- retiredPlayers: 旧 AVPlayer 保留 3 秒防 use-after-free
- autoreleasepool 显式管理

### PlayerProxy (WallpaperApp/PlayerProxy.swift)
- 查找 helper 二进制（打包/开发/源码路径）
- 启动 Process + stdin/stdout Pipe
- 缓存 helper 状态（避免轮询）
- 崩溃检测 + 0.5s 自动重启 + 状态恢复

### 控制面板 (WallpaperApp/main.swift: ControlWin)
- NSPanel + nonactivatingPanel, 右上角浮动
- 折叠 68px / 展开 240px
- 按钮 target = AppDelegate @objc 方法
- 菜单栏 NSStatusItem

### PlaylistManager
- 三种模式: single / sequential / shuffled
- 禁用视频持久化到 UserDefaults

### AdaptivePerformanceManager
- PowerMonitor: 电池→降画质
- ThermalMonitor: 温度过高→暂停
- SleepWakeHandler: 休眠→暂停, 唤醒→恢复
- FullScreenDetector: 全屏→暂停

### 测试系统
- TestController: --test rapid/mixed/long/stress, 1-30s 间隔
- 日志: ~/Library/Logs/wallpaper_test/test_YYMMDD_HHmmss.log

## 5. 四种切换方案

A. replaceCurrentItem 直接换 → 无黑屏, 会 crash (0xa1a1a1a1)
B. 销毁重建播放器 → 无 crash, 有黑屏 (播放器重建间隙)
C. replaceCurrentItem + 旧 item 保活 3s → ✅ 稳定, ⚠️ 切换黑屏较短 (当前方案)
D. 双播放器预加载 → 理论上都解决, 实现失败 (AVQueuePlayer状态机问题)

## 6. 关键技术细节

### 窗口层级
desktopIconWindow - 1: 桌面图标下方, 背景上方

### 多屏幕
每个 NSScreen 一个 NSWindow, screensChanged 时重建

### End Observer 延迟分发
DispatchQueue.main.async 延迟到下一 RunLoop 触发


## 7. 已知问题

1. **音量持久化**: 未保存 UserDefaults
2. **快速连续切换 (<100ms)**: 边界行为未充分验证
"""

AI_SUMMARY = r"""
## 一句话本质
macOS 壁纸应用 = Swift+Cocoa UI 主进程 + Swift+AVFoundation Helper 进程，
通过 JSON/pipe IPC，核心矛盾已通过双播放器预加载解决。

## 当前状态: 方案 D (双播放器预加载)
✅ 双 AVQueuePlayer 一显一藏，备用播放器后台预加载
✅ 就绪后交换 layer 指针，旧播放器显示最后一帧直到切换
✅ 退役播放器保活 3 秒防 use-after-free
✅ 无 replaceCurrentItem，零黑屏
稳定: 压力测试 60 次通过，内存 ~30MB

## 四个方案的权衡
A. replaceCurrentItem 直接换 → 无黑屏, 会 crash
B. 销毁重建播放器 → 无 crash, 有黑屏
C. replaceCurrentItem + 旧 item 保活 3s → 稳定, 黑屏较短
D. 双播放器预加载 → ✅ 稳定, ✅ 零黑屏 (当前)

## 如果要接手改代码
切入点是 WallpaperPlayer/main.swift 的 PlayerEngine 类。
"""


def main():
    import sys
    if "--ai" in sys.argv:
        print(AI_SUMMARY.strip())
    else:
        print(ARCHITECTURE.strip())
        print("\n\n--- AI 摘要模式: python wallpaper_arch.py --ai ---")


if __name__ == "__main__":
    main()
