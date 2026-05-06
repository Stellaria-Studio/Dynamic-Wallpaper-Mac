import Cocoa
import AVFoundation
import Foundation

// MARK: - Types
enum VideoQuality: String { case high = "1080p", original = "原画", fourK = "4K" }
enum VideoFramerate: String { case auto = "自动", fps30 = "30fps", fps60 = "60fps" }

let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif"]
func isImageFile(_ url: URL) -> Bool { imageExts.contains(url.pathExtension.lowercased()) }

// MARK: - VideoPlayerView

class VideoPlayerView: NSView {
    private var playerLayer: AVPlayerLayer?
    var imageLayer: CALayer?
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let l = AVPlayerLayer()
        l.videoGravity = .resizeAspectFill
        l.needsDisplayOnBoundsChange = true
        l.frame = bounds
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer = l
        layer?.addSublayer(l)
        let imgLayer = CALayer()
        imgLayer.contentsGravity = .resizeAspectFill
        imgLayer.frame = bounds
        imgLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imgLayer.isHidden = true
        imageLayer = imgLayer
        layer?.addSublayer(imgLayer)
    }
    func attach(player: AVPlayer) { playerLayer?.player = player }
    func detach() { playerLayer?.player = nil }
    var isVideoReadyForDisplay: Bool { playerLayer?.isReadyForDisplay ?? false }

    func showImage(_ image: NSImage) {
        playerLayer?.isHidden = true
        imageLayer?.isHidden = false
        imageLayer?.contents = image
    }

    func showVideo() {
        imageLayer?.isHidden = true
        playerLayer?.isHidden = false
    }
}

// MARK: - Memory Monitor

var peakMemory: UInt64 = 0

func getMemoryUsage() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

// MARK: - PlayerEngine (双播放器预加载方案 D)

/*
 维护两个独立的 AVQueuePlayer（playerA / playerB），一显一藏。
 切换时备用播放器在后台预加载，就绪后直接交换 layer 指针，旧播放器继续显示
 最后一帧直到新播放器接管。零黑屏。

 关键设计:
   1. AVQueuePlayer(items:) 创建带 item 的播放器（而非空队列 + replaceCurrentItem）
   2. currentItem.status 检查真实解码就绪（而非 player.status）
   3. performSwitch 中先配置 looper/observer 再 attach layer，消除黑帧
   4. generation 计数器防止陈旧异步回调
   5. 退役播放器 3 秒保活 + 防重复加入
   6. 等待超时 5 秒降级执行 + 错误日志
*/

class PlayerEngine: NSObject {

    // ========================================================================
    // MARK: - 双播放器
    // ========================================================================

    private var playerA: AVQueuePlayer?
    private var playerB: AVQueuePlayer?
    private var looperA: AVPlayerLooper?
    private var looperB: AVPlayerLooper?
    private var activeIsA = true

    private var currentPlayer: AVQueuePlayer? { activeIsA ? playerA : playerB }
    private var standbyPlayer: AVQueuePlayer? { activeIsA ? playerB : playerA }
    private var currentLooper: AVPlayerLooper? { activeIsA ? looperA : looperB }

    private var currentURL: URL?

    // 退役播放器保活列表 — 3 秒后释放防 use-after-free
    private var retiredPlayers: [AVPlayer] = []

    // 预加载状态管理
    private var preloadWorkItem: DispatchWorkItem?
    private var switchGeneration = 0

    // ========================================================================
    // MARK: - 窗口

    private var windows: [NSWindow] = []
    private var playerViews: [VideoPlayerView] = []

    // ========================================================================
    // MARK: - End Observer

    private var endObservers: [NSObjectProtocol] = []

    // ========================================================================
    // MARK: - 播放状态

    private(set) var isUserPaused = false
    private(set) var isPerformancePaused = false
    var isPaused: Bool { isUserPaused || isPerformancePaused }
    var isHidden = false
    var isMuted = true { didSet {
        currentPlayer?.isMuted = isMuted
        standbyPlayer?.isMuted = isMuted
    } }
    var volume: Float = 1.0 { didSet {
        currentPlayer?.volume = volume
        standbyPlayer?.volume = volume
    } }
    var quality: VideoQuality = .high
    var singleMode = false
    private(set) var currentIsImage = false
    var onVideoEnd: (() -> Void)?

    // ========================================================================
    // MARK: - 启动
    // ========================================================================

    func start(url: URL, quality q: VideoQuality, muted: Bool, singleMode s: Bool) {
        if isImageFile(url) {
            displayImage(url: url)
            return
        }

        quality = q; isMuted = muted; singleMode = s

        destroyBothPlayers()

        // 改进 #7: 确保窗口存在
        if playerViews.isEmpty {
            createWindowsForAllScreens()
        }

        // 创建 playerA 作为初始播放器
        let newPlayer = AVQueuePlayer()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        configureItem(item)

        newPlayer.insert(item, after: nil)
        if singleMode {
            setupSingleModeObserver(player: newPlayer, item: item)
        } else {
            setupEndObserver(player: newPlayer, item: item)
        }

        newPlayer.isMuted = isMuted
        newPlayer.volume = volume
        playerA = newPlayer
        playerB = nil
        activeIsA = true
        currentURL = url

        attachPlayerToAllWindows(newPlayer)
        newPlayer.play()
        isUserPaused = false; isPerformancePaused = false

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        reportPlaying(url: url)
    }

    // ========================================================================
    // MARK: - 视频切换
    // ========================================================================

    func switchVideo(url: URL, quality q: VideoQuality? = nil) {
        if isImageFile(url) {
            displayImage(url: url)
            return
        }

        if let q = q { quality = q }
        guard url != currentURL || currentIsImage else { return }

        currentURL = url

        // 首次调用：无播放器，直接初始化
        guard playerA != nil || playerB != nil else {
            if playerViews.isEmpty { createWindowsForAllScreens() }

            let newPlayer = AVQueuePlayer()
            let item = AVPlayerItem(asset: AVURLAsset(url: url))
            configureItem(item)

            newPlayer.insert(item, after: nil)
            if singleMode {
                setupSingleModeObserver(player: newPlayer, item: item)
            } else {
                setupEndObserver(player: newPlayer, item: item)
            }

            newPlayer.isMuted = isMuted
            newPlayer.volume = volume
            playerA = newPlayer
            activeIsA = true

            // Start playback first so newPlayer has decoded frames
            newPlayer.play()
            isUserPaused = false; isPerformancePaused = false

            if currentIsImage {
                // 照片→视频：新视频覆盖层在旧图片上方渐显
                performBlackFadeTransition(newPlayer: newPlayer)
            } else {
                // 无旧内容，直接显示
                for v in playerViews { v.showVideo() }
                attachPlayerToAllWindows(newPlayer)
            }
            currentIsImage = false

            reportPlaying(url: url)
            return
        }

        // 取消上次未完成的预加载
        preloadWorkItem?.cancel()

        let gen = switchGeneration + 1
        switchGeneration = gen

        let workItem = DispatchWorkItem { [weak self] in
            self?.preloadAndSwitch(gen: gen, url: url)
        }
        preloadWorkItem = workItem

        DispatchQueue.main.async(execute: workItem)
    }

    /// 在备用播放器槽位中创建新播放器并等待就绪
    private func preloadAndSwitch(gen: Int, url: URL) {
        guard gen == switchGeneration else { return }

        autoreleasepool {
            let newItem = AVPlayerItem(asset: AVURLAsset(url: url))
            configureItem(newItem)

            // 使用 AVQueuePlayer(items:) 创建，确保 currentItem 立即可用
            let newPlayer = AVQueuePlayer(items: [newItem])

            // 改进 #5: 立即同步音量/静音状态
            newPlayer.isMuted = isMuted
            newPlayer.volume = volume

            // 不暂停 — 就绪后播放解码首帧

            // 存入备用槽位，清理旧备用
            if activeIsA {
                looperB?.disableLooping(); looperB = nil
                playerB?.pause()
                playerB?.removeAllItems()
                playerB = newPlayer
            } else {
                looperA?.disableLooping(); looperA = nil
                playerA?.pause()
                playerA?.removeAllItems()
                playerA = newPlayer
            }

            // 轮询等待就绪
            waitForItemThenSwitch(newPlayer, gen: gen, retries: 50)
        }
    }

    /// 轮询检查 currentItem.status，就绪后播放解码首帧再切换
    private func waitForItemThenSwitch(_ player: AVQueuePlayer, gen: Int, retries: Int) {
        // 改进 #1: 使用捕获的 gen 局部变量与 switchGeneration 比较
        guard gen == switchGeneration else { return }

        if player.currentItem?.status == .readyToPlay {
            // 开始播放解码首帧，确保 attach layer 时已有画面
            player.play()
            // 等 100ms（约 3 帧 @30fps）确保至少一帧已解码
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.performSwitch(newPlayer: player, gen: gen)
            }
        } else if retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForItemThenSwitch(player, gen: gen, retries: retries - 1)
            }
        } else {
            // 改进 #2: 超时降级 — 仍尝试播放解码再切换但记录错误
            writeEvent("error", ["message": "switch timeout: item not ready after 5s"])
            player.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.performSwitch(newPlayer: player, gen: gen)
            }
        }
    }

    /// 执行实际的播放器切换（页面先变黑，再切到新内容）
    private func performSwitch(newPlayer: AVQueuePlayer, gen: Int) {
        guard gen == switchGeneration else { return }

        // 7a. 销毁旧 endObserver
        removeEndObserver()

        // 7b. 销毁旧 looper — 改进 #4: BOTH 彻底清理
        looperA?.disableLooping(); looperA = nil
        looperB?.disableLooping(); looperB = nil

        // 7c. 保存当前显示的播放器
        let oldPlayer = currentPlayer

        // 7d. 为新播放器设置循环/结束观察者（activeIsA 还没切换，但 observers 是直接关联 newPlayer 的）
        if singleMode {
            if let item = newPlayer.currentItem {
                setupSingleModeObserver(player: newPlayer, item: item)
            }
        } else {
            if let item = newPlayer.currentItem {
                setupEndObserver(player: newPlayer, item: item)
            }
        }

        // 7e. 黑场过渡：先盖黑，再在黑场下切到新播放器，最后从黑场退开
        performBlackFadeTransition(newPlayer: newPlayer)
        currentIsImage = false
        activeIsA.toggle()

        // 7g. 同步 mute / volume / rate（立即应用，动画过程中已生效）
        newPlayer.isMuted = isMuted
        newPlayer.volume = volume
        syncRate()

        // 开始播放
        if !isPaused { newPlayer.play() }

        // 7h. 0.65s 后退役旧播放器（等待黑场过渡完成）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self, oldPlayer] in
            guard let self else { return }
            oldPlayer?.pause()
            if let old = oldPlayer {
                if !self.retiredPlayers.contains(where: { $0 === old }) {
                    self.retiredPlayers.append(old)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, old] in
                        self?.retiredPlayers.removeAll { $0 === old }
                    }
                }
            }
        }

        // 7i. 报告状态
        reportPlaying(url: currentURL)
    }

    // ========================================================================
    // MARK: - 黑场过渡
    // ========================================================================

    /// 页面整体先淡入黑色遮罩，在全黑时替换底层内容。
    /// 对视频会等到 AVPlayerLayer 真正 readyForDisplay 后再退黑，尽量挡住接管后的异常闪帧。
    private func performBlackFadeTransition(
        duration: TimeInterval = 0.6,
        newPlayer: AVQueuePlayer? = nil,
        newImage: NSImage? = nil
    ) {
        let halfDuration = duration / 2
        let revealDelayAfterReady: TimeInterval = 0.12
        let maxBlackHold: TimeInterval = 0.45
        var blackOverlays: [CALayer] = []

        func fadeOutBlackOverlays() {
            for overlay in blackOverlays {
                overlay.opacity = 1  // 同步到当前动画终点，再移除动画就不会闪
                overlay.removeAnimation(forKey: "fadeToBlack")
                if overlay.animation(forKey: "fadeFromBlack") != nil { continue }

                let fadeFromBlack = CABasicAnimation(keyPath: "opacity")
                fadeFromBlack.fromValue = 1
                fadeFromBlack.toValue = 0
                fadeFromBlack.duration = halfDuration
                fadeFromBlack.fillMode = .forwards
                fadeFromBlack.isRemovedOnCompletion = false
                overlay.add(fadeFromBlack, forKey: "fadeFromBlack")
            }
        }

        func waitUntilVideoStable(startedAt: CFTimeInterval, deadline: CFTimeInterval) {
            let now = CACurrentMediaTime()
            let allReady = !playerViews.isEmpty && playerViews.allSatisfy { $0.isVideoReadyForDisplay }

            if allReady {
                let readySince = now - startedAt
                if readySince >= revealDelayAfterReady || now >= deadline {
                    fadeOutBlackOverlays()
                    return
                }
            } else if now >= deadline {
                fadeOutBlackOverlays()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                waitUntilVideoStable(startedAt: startedAt, deadline: deadline)
            }
        }

        for v in playerViews {
            let blackOverlay = CALayer()
            blackOverlay.frame = v.bounds
            blackOverlay.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            blackOverlay.backgroundColor = NSColor.black.cgColor
            blackOverlay.opacity = 0
            blackOverlay.zPosition = 10
            v.layer?.addSublayer(blackOverlay)
            blackOverlays.append(blackOverlay)

            let fadeToBlack = CABasicAnimation(keyPath: "opacity")
            fadeToBlack.fromValue = 0
            fadeToBlack.toValue = 1
            fadeToBlack.duration = halfDuration
            fadeToBlack.fillMode = .forwards
            fadeToBlack.isRemovedOnCompletion = false
            blackOverlay.add(fadeToBlack, forKey: "fadeToBlack")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + halfDuration) { [weak self] in
            guard let self else { return }
            for v in self.playerViews {
                if let player = newPlayer {
                    v.attach(player: player)
                    v.showVideo()
                } else if let img = newImage {
                    v.showImage(img)
                }
            }

            if newPlayer != nil {
                let startedAt = CACurrentMediaTime()
                waitUntilVideoStable(startedAt: startedAt, deadline: startedAt + maxBlackHold)
            } else {
                fadeOutBlackOverlays()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + maxBlackHold + 0.1) {
            for overlay in blackOverlays {
                overlay.opacity = 0
                overlay.removeAllAnimations()
                overlay.removeFromSuperlayer()
            }
        }
    }

    // ========================================================================
    // MARK: - 图片播放
    // ========================================================================

    func displayImage(url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            writeEvent("error", ["message": "failed to load image: \(url.lastPathComponent)"])
            return
        }

        if playerViews.isEmpty {
            createWindowsForAllScreens()
            for v in playerViews { v.showImage(image) }
            currentIsImage = true
            currentURL = url
            reportPlaying(url: url)
            return
        }

        removeEndObserver()
        playerA?.pause()
        playerB?.pause()

        // 顶层淡入：新图片覆盖层在旧内容上方渐显
        performBlackFadeTransition(newImage: image)

        currentIsImage = true
        currentURL = url
        reportPlaying(url: url)
    }

    // ========================================================================
    // MARK: - 销毁
    // ========================================================================

    private func destroyBothPlayers() {
        guard playerA != nil || playerB != nil else { return }

        for v in playerViews { v.detach() }

        autoreleasepool {
            looperA?.disableLooping(); looperA = nil
            looperB?.disableLooping(); looperB = nil
            removeEndObserver()

            playerA?.pause()
            playerA?.removeAllItems()
            playerA = nil

            playerB?.pause()
            playerB?.removeAllItems()
            playerB = nil

            retiredPlayers.removeAll()
        }

        currentURL = nil
        preloadWorkItem?.cancel()
        preloadWorkItem = nil
    }

    func cleanup() {
        NotificationCenter.default.removeObserver(self)
        destroyBothPlayers()
        for w in windows { w.close() }
        windows.removeAll(); playerViews.removeAll()
    }

    deinit { cleanup() }

    // ========================================================================
    // MARK: - 播放控制
    // ========================================================================

    func setPaused(_ paused: Bool) { isUserPaused = paused; syncRate(); reportStatus() }
    func togglePause() { isUserPaused.toggle(); syncRate(); reportStatus() }
    func setPerformancePaused(_ v: Bool) { isPerformancePaused = v; syncRate(); reportStatus() }
    func forcePause() { currentPlayer?.rate = 0 }
    func resumeIfNotPaused() { if !isPaused { currentPlayer?.rate = 1 } }
    private func syncRate() { currentPlayer?.rate = isPaused ? 0 : 1 }

    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        writeEvent("volume", ["value": volume])
    }

    func setHidden(_ h: Bool) {
        isHidden = h
        if h { windows.forEach { $0.orderOut(nil) } }
        else { windows.forEach { $0.orderFrontRegardless() } }
        writeEvent("hidden", ["value": h])
    }
    func toggleHidden() { setHidden(!isHidden) }

    func setMuted(_ m: Bool) { isMuted = m; writeEvent("muted", ["value": m]) }
    func toggleMute() { setMuted(!isMuted) }

    // ========================================================================
    // MARK: - Item 配置
    // ========================================================================

    private func configureItem(_ item: AVPlayerItem) {
        if quality == .fourK { item.preferredForwardBufferDuration = 0 }
        else {
            item.preferredForwardBufferDuration = 0.5
            if quality == .high {
                item.preferredMaximumResolution = .init(width: 1920, height: 1080)
            } else if let s = NSScreen.main {
                let pw = s.frame.width * s.backingScaleFactor
                let ph = s.frame.height * s.backingScaleFactor
                item.preferredMaximumResolution = .init(width: pw, height: ph)
            }
        }
    }

    // ========================================================================
    // MARK: - End Observer
    // ========================================================================

    private func setupEndObserver(player p: AVPlayer, item: AVPlayerItem) {
        removeEndObserver()
        let obs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self, weak p] _ in
            // 立即 pause 防止 AVQueuePlayer 自动 advance 清空 currentItem
            p?.pause()
            self?.onVideoEnd?()
            writeEvent("videoEnded", [:])
        }
        endObservers = [obs]
    }

    /// singleMode 无缝循环：双队列策略
    ///
    /// 创建第二个 AVPlayerItem（相同 URL）插入队列末尾。
    /// item1 播完 → AVQueuePlayer 自动无缝切换到 item2（零黑帧）
    /// item1 的 observer 触发 → seek-to-zero → 插回 item2 之后
    /// item2 播完 → 同理 seek 再插回 item1 之后
    /// 以此循环，队列永不空，layer 永不黑。
    private func setupSingleModeObserver(player p: AVPlayer, item: AVPlayerItem) {
        removeEndObserver()

        // 创建第二个 item 用于无缝衔接
        if let asset = item.asset as? AVURLAsset {
            let standbyItem = AVPlayerItem(asset: AVURLAsset(url: asset.url))
            configureItem(standbyItem)

            if let qp = p as? AVQueuePlayer {
                qp.insert(standbyItem, after: nil)
            }

            // 两个 item 共享同一个 observer：seek 已结束的 item 到零，插回队尾
            let makeObserver: (AVPlayerItem) -> NSObjectProtocol = { [weak p] targetItem in
                NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                    object: targetItem, queue: .main) { notification in
                    guard let p = p, let endedItem = notification.object as? AVPlayerItem else { return }
                    endedItem.seek(to: .zero) { _ in
                        if let qp = p as? AVQueuePlayer {
                            qp.insert(endedItem, after: nil)
                        }
                    }
                }
            }

            endObservers = [makeObserver(item), makeObserver(standbyItem)]
        } else {
            // 降级：单 item seek + 重插入（可能有短暂黑帧）
            let obs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                object: item, queue: .main) { [weak p] notification in
                guard let p = p, let endedItem = notification.object as? AVPlayerItem else { return }
                endedItem.seek(to: .zero) { _ in
                    if let qp = p as? AVQueuePlayer, qp.items().isEmpty {
                        qp.insert(endedItem, after: nil)
                    }
                    p.play()
                }
            }
            endObservers = [obs]
        }
    }

    private func removeEndObserver() {
        for o in endObservers { NotificationCenter.default.removeObserver(o) }
        endObservers.removeAll()
    }

    // ========================================================================
    // MARK: - 窗口管理
    // ========================================================================

    private func createWindowsForAllScreens() {
        for screen in NSScreen.screens { addWindow(screen: screen) }
    }

    private func addWindow(screen: NSScreen) {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        w.isOpaque = true; w.backgroundColor = .black; w.hasShadow = false; w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        guard let contentView = w.contentView else { return }
        let v = VideoPlayerView(frame: contentView.bounds)
        v.autoresizingMask = [.width, .height]
        w.contentView = v; w.makeKeyAndOrderFront(nil); w.orderFrontRegardless()
        windows.append(w); playerViews.append(v)
    }

    private func attachPlayerToAllWindows(_ player: AVPlayer) {
        for v in playerViews { v.attach(player: player) }
    }

    @objc private func screensChanged() {
        guard currentPlayer != nil else { return }
        for v in playerViews { v.detach() }
        for w in windows { w.close() }; windows.removeAll(); playerViews.removeAll()
        createWindowsForAllScreens()
        if let p = currentPlayer { attachPlayerToAllWindows(p) }
        if isHidden { windows.forEach { $0.orderOut(nil) } }
    }

    // ========================================================================
    // MARK: - 事件报告
    // ========================================================================

    func reportPlaying(url: URL?) {
        if let u = url { writeEvent("playing", ["url": u.path]) }
        reportStatus()
    }

    func reportStatus() {
        writeEvent("status", [
            "paused": isPaused, "muted": isMuted, "hidden": isHidden,
            "userPaused": isUserPaused, "perfPaused": isPerformancePaused,
            "volume": volume
        ])
    }
}

// MARK: - Event Writer

func writeEvent(_ event: String, _ data: [String: Any] = [:]) {
    let mem = Double(getMemoryUsage()) / 1048576.0
    if mem > Double(peakMemory) { peakMemory = getMemoryUsage() }
    var d = data
    d["event"] = event
    d["mb"] = round(mem * 10) / 10
    guard let json = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    fflush(stdout)
}

// MARK: - Command Handler

class CommandHandler: NSObject {
    let engine = PlayerEngine()
    var buffer = ""

    override init() {
        super.init()
        engine.onVideoEnd = { }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            writeEvent("ready", [:])
        }
    }

    func processInput(_ data: Data) {
        buffer += String(data: data, encoding: .utf8) ?? ""
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl])
            buffer = String(buffer[buffer.index(after: nl)...])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { handleCommand(trimmed) }
        }
    }

    private func handleCommand(_ json: String) {
        guard let data = json.data(using: .utf8),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = cmd["cmd"] as? String else {
            writeEvent("error", ["message": "bad command"])
            return
        }

        switch action {
        case "start":
            guard let urlStr = cmd["url"] as? String else { return }
            let url = URL(fileURLWithPath: urlStr)
            let q = (cmd["quality"] as? String).flatMap { VideoQuality(rawValue: $0) } ?? .high
            let muted = cmd["muted"] as? Bool ?? true
            let single = cmd["singleMode"] as? Bool ?? false
            engine.start(url: url, quality: q, muted: muted, singleMode: single)

        case "showImage":
            guard let urlStr = cmd["url"] as? String else { return }
            engine.displayImage(url: URL(fileURLWithPath: urlStr))

        case "switchVideo":
            guard let urlStr = cmd["url"] as? String else { return }
            let url = URL(fileURLWithPath: urlStr)
            let q = (cmd["quality"] as? String).flatMap { VideoQuality(rawValue: $0) }
            if let single = cmd["singleMode"] as? Bool { engine.singleMode = single }
            engine.switchVideo(url: url, quality: q)

        case "setPaused":
            if let v = cmd["value"] as? Bool { engine.setPaused(v) }

        case "setPerformancePaused":
            if let v = cmd["value"] as? Bool { engine.setPerformancePaused(v) }

        case "forcePause":
            engine.forcePause()

        case "resumeIfNotPaused":
            engine.resumeIfNotPaused()

        case "setHidden":
            if let v = cmd["value"] as? Bool { engine.setHidden(v) }

        case "toggleHidden":
            engine.toggleHidden()

        case "setMuted":
            if let v = cmd["value"] as? Bool { engine.setMuted(v) }

        case "toggleMute":
            engine.toggleMute()

        case "setVolume":
            if let v = cmd["value"] as? Double { engine.setVolume(Float(v)) }

        case "setSingleMode":
            if let v = cmd["value"] as? Bool { engine.singleMode = v }

        case "setQuality":
            if let v = cmd["value"] as? String, let q = VideoQuality(rawValue: v) {
                engine.quality = q
            }

        case "cleanup":
            engine.cleanup()

        case "queryState":
            engine.reportStatus()

        default:
            writeEvent("error", ["message": "unknown command: \(action)"])
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let handler = CommandHandler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let stdinFH = FileHandle.standardInput
        stdinFH.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                return
            }
            DispatchQueue.main.async { self?.handler.processInput(data) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        handler.engine.cleanup()
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
