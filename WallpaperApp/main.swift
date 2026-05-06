import Cocoa
import AVFoundation
// (Global hotkeys are handled via NSMenu key equivalents in rebuildMenu)

// MARK: - Video Processing
enum VideoQuality: String { case high = "1080p", original = "原画", fourK = "4K" }
enum PlayMode: String { case single = "循环", sequential = "顺序", shuffled = "随机" }
enum VideoFramerate: String { case auto = "自动", fps30 = "30fps", fps60 = "60fps" }
enum MediaMode: String { case video = "视频", photo = "照片" }

func getVideoSize(_ url: URL) async -> (Int, Int) {
    let a = AVURLAsset(url: url)
    guard let t = try? await a.loadTracks(withMediaType: .video).first,
          let d = try? await t.load(.formatDescriptions), let f = d.first else { return (0,0) }
    let dim = CMVideoFormatDescriptionGetDimensions(f)
    return (Int(dim.width), Int(dim.height))
}

func processVideo(url: URL, quality: VideoQuality) async -> URL {
    let (w, h) = await getVideoSize(url)
    guard quality == .high, max(w, h) > 1080 else { return url }
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("wp_\(UUID().uuidString).mp4")
    guard let s = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPreset1920x1080) else { return url }
    do { try await s.export(to: out, as: .mp4); return out }
    catch { try? FileManager.default.removeItem(at: out); return url }
}

// MARK: - Playlist Manager
class PlaylistManager {
    var videos: [URL] = []
    private(set) var index = 0
    var mode: PlayMode = .sequential { didSet { build() } }
    private var order: [Int] = [], pos = 0
    var isEmpty: Bool { videos.isEmpty }
    var count: Int { videos.count }
    var current: URL? { videos.isEmpty ? nil : videos[index] }
    var name: String { current?.lastPathComponent ?? "(无)" }

    // Disabled videos (UserDefaults-persisted)
    private var disabledPaths: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "disabledWallpapers") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "disabledWallpapers") }
    }
    func isEnabled(_ url: URL) -> Bool { !disabledPaths.contains(url.path) }
    func toggle(_ url: URL) {
        var s = disabledPaths
        if s.contains(url.path) { s.remove(url.path) } else { s.insert(url.path) }
        disabledPaths = s
    }

    init() { build() }
    private func build() {
        guard !videos.isEmpty else { order = []; pos = 0; return }
        order = mode == .shuffled ? (0..<videos.count).shuffled() : Array(0..<videos.count)
        if let p = order.firstIndex(of: min(index, videos.count-1)) { pos = p } else { pos = 0; index = order.first ?? 0 }
    }

    func set(_ urls: [URL]) { videos = urls; index = 0; build(); skipToFirstEnabled() }
    func add(_ urls: [URL]) { videos.append(contentsOf: urls); build() }
    func jump(i: Int) -> URL? {
        guard i >= 0, i < videos.count else { return nil }
        guard isEnabled(videos[i]) else { return nil } // Don't jump to disabled
        index = i; if let p = order.firstIndex(of: i) { pos = p }; return videos[i]
    }
    func next() -> URL? {
        guard !videos.isEmpty, !order.isEmpty else { return nil }
        var attempts = 0
        repeat {
            pos += 1; if pos >= order.count { build(); pos = 0 }
            attempts += 1; if attempts > videos.count { return nil }
        } while !isEnabled(videos[order[pos]])
        index = order[pos]; return videos[index]
    }
    func prev() -> URL? {
        guard !videos.isEmpty, !order.isEmpty else { return nil }
        var attempts = 0
        repeat {
            pos -= 1; if pos < 0 { pos = order.count - 1 }
            attempts += 1; if attempts > videos.count { return nil }
        } while !isEnabled(videos[order[pos]])
        index = order[pos]; return videos[index]
    }
    var isSingleMode: Bool { mode == .single }

    private func skipToFirstEnabled() {
        guard !videos.isEmpty else { return }
        for i in 0..<videos.count {
            if isEnabled(videos[i]) { index = i; if let p = order.firstIndex(of: i) { pos = p }; return }
        }
    }
}

// MARK: - Folder Watcher
class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    func start(path: String, onChange: @escaping () -> Void) {
        stop()
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source?.setEventHandler { onChange() }
        source?.resume()
    }

    func stop() {
        source?.cancel(); source = nil
        if fd >= 0 { close(fd); fd = -1 }
    }
    deinit { stop() }
}

// MARK: - Media Folders
let videoFolderURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("壁纸素材")
let videoSubfolderURL = videoFolderURL.appendingPathComponent("视频")
let photoSubfolderURL = videoFolderURL.appendingPathComponent("照片")

let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]
let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif"]

func scanVideoFolder() -> [URL] {
    var urls: [URL] = []
    if let vu = try? FileManager.default.contentsOfDirectory(at: videoSubfolderURL, includingPropertiesForKeys: nil) {
        urls.append(contentsOf: vu.filter { videoExts.contains($0.pathExtension.lowercased()) })
    }
    if let pu = try? FileManager.default.contentsOfDirectory(at: photoSubfolderURL, includingPropertiesForKeys: nil) {
        urls.append(contentsOf: pu.filter { imageExts.contains($0.pathExtension.lowercased()) })
    }
    return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
}
func isImageFile(_ url: URL) -> Bool { imageExts.contains(url.pathExtension.lowercased()) }

// MARK: - Control Panel 子类

/// 可以成为 Key Window 的面板，按钮点击正常，但不抢其他 app 焦点
private final class ControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Control Window（媒体播放器风格，固定布局）

class ControlWin: NSObject, NSWindowDelegate {
    private let panel: ControlPanel
    unowned let app: AppDelegate

    // 面板尺寸
    private let panelWidth: CGFloat = 250
    private let videoPanelHeight: CGFloat = 290
    private let photoPanelHeight: CGFloat = 260

    // ---- UI 控件 ----

    private let nameLabel: NSTextField = {
        let l = NSTextField(labelWithString: "未播放")
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.lineBreakMode = .byTruncatingMiddle
        l.alignment = .center
        l.textColor = .secondaryLabelColor
        return l
    }()

    // 传输控制
    private let prevBtn: NSButton = {
        let b = NSButton(title: "◀", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 18)
        return b
    }()
    private let playBtn: NSButton = {
        let b = NSButton(title: "⏸", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 18)
        return b
    }()
    private let nextBtn: NSButton = {
        let b = NSButton(title: "▶", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 18)
        return b
    }()

    // 音量
    private let musicBtn: NSButton = {
        let b = NSButton(title: "🔊", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }()
    private let volumeSlider: NSSlider = {
        let s = NSSlider(value: 1.0, minValue: 0, maxValue: 1.0, target: nil, action: nil)
        s.controlSize = .small
        s.numberOfTickMarks = 0
        s.isEnabled = true
        return s
    }()

    // 设置
    private let modePop: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.controlSize = .small
        return p
    }()
    private let qualityPop: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.controlSize = .small
        return p
    }()
    private let fpsPop: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.controlSize = .small
        return p
    }()

    // 操作按钮
    private let hideBtn: NSButton = {
        let b = NSButton(title: "隐藏壁纸", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }()
    private let quitBtn: NSButton = {
        let b = NSButton(title: "退出", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }()

    // 播放列表
    private let playlistStack: NSStackView = {
        let s = NSStackView()
        s.orientation = .vertical
        s.spacing = 2
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()
    private let playlistScroll: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.borderType = .noBorder
        sv.drawsBackground = false
        return sv
    }()
    private let playlistLabel: NSTextField = {
        let l = NSTextField(labelWithString: "播放列表")
        l.font = .systemFont(ofSize: 10, weight: .medium)
        l.textColor = .secondaryLabelColor
        l.alignment = .left
        return l
    }()

    // 状态
    private let statusLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 9)
        l.textColor = .tertiaryLabelColor
        l.alignment = .center
        return l
    }()

    // mode popup 用纯中文（避免 enum rawValue 中 emoji 显示问题）
    private let modeLabels = ["循环", "顺序", "随机"]
    private let intervalLabels = ["3秒", "5秒", "10秒", "30秒", "手动"]
    private let intervalValues: [TimeInterval] = [3, 5, 10, 30, 0]

    // 视频/照片切换
    private let modeSwitch: NSSegmentedControl = {
        let s = NSSegmentedControl(labels: ["视频", "照片"], trackingMode: .selectOne, target: nil, action: nil)
        s.selectedSegment = 0; s.controlSize = .small
        return s
    }()

    // 照片滑映间隔
    private let intervalPop: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.controlSize = .small; return p
    }()

    // 视频/照片专属控件容器
    private let videoSection = NSStackView()
    private let photoSection = NSStackView()

    // MARK: - Init

    init(app: AppDelegate) {
        self.app = app
        let f = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let r = NSRect(x: f.maxX - panelWidth - 16, y: f.maxY - videoPanelHeight - 8, width: panelWidth, height: videoPanelHeight)
        panel = ControlPanel(contentRect: r,
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        super.init()
        panel.title = "动态壁纸"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.delegate = self
        setupUI()
        setupActions()
        panel.standardWindowButton(.closeButton)?.target = app
        panel.standardWindowButton(.closeButton)?.action = #selector(AppDelegate.stopAndQuit)
        panel.standardWindowButton(.miniaturizeButton)?.target = self
        panel.standardWindowButton(.miniaturizeButton)?.action = #selector(hidePanel)
    }

    // MARK: - 布局

    private func setupUI() {
        guard let cv = panel.contentView else { return }

        let sep: () -> NSBox = { let b = NSBox(); b.boxType = .separator; return b }

        // 传输行
        let transportRow = NSStackView(views: [prevBtn, playBtn, nextBtn])
        transportRow.spacing = 8; transportRow.alignment = .centerY

        // ---- 视频专属控件 ----
        let volumeRow = NSStackView(views: [musicBtn, volumeSlider])
        volumeRow.spacing = 4; volumeRow.alignment = .centerY
        volumeSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let modeLabel = makeLabel("模式")
        let qualityLabel = makeLabel("画质")
        modePop.addItems(withTitles: modeLabels)
        modePop.widthAnchor.constraint(greaterThanOrEqualToConstant: 85).isActive = true
        qualityPop.addItems(withTitles: [VideoQuality.high.rawValue, VideoQuality.original.rawValue, VideoQuality.fourK.rawValue])
        qualityPop.widthAnchor.constraint(greaterThanOrEqualToConstant: 85).isActive = true

        let fpsLabel = makeLabel("帧率")
        fpsPop.addItems(withTitles: [VideoFramerate.auto.rawValue, VideoFramerate.fps30.rawValue, VideoFramerate.fps60.rawValue])
        fpsPop.widthAnchor.constraint(greaterThanOrEqualToConstant: 85).isActive = true

        let settingsRow1 = NSStackView(views: [modeLabel, modePop, qualityLabel, qualityPop])
        settingsRow1.spacing = 4; settingsRow1.alignment = .centerY
        let settingsRow2 = NSStackView(views: [fpsLabel, fpsPop])
        settingsRow2.spacing = 4; settingsRow2.alignment = .centerY

        videoSection.setViews([volumeRow, settingsRow1, settingsRow2], in: .leading)
        videoSection.orientation = .vertical; videoSection.spacing = 3
        videoSection.detachesHiddenViews = true

        // ---- 照片专属控件 ----
        let intervalLabel = makeLabel("间隔")
        intervalPop.addItems(withTitles: intervalLabels)
        intervalPop.selectItem(at: 1) // 默认 5 秒
        intervalPop.widthAnchor.constraint(greaterThanOrEqualToConstant: 85).isActive = true

        let intervalRow = NSStackView(views: [intervalLabel, intervalPop])
        intervalRow.spacing = 4; intervalRow.alignment = .centerY

        photoSection.setViews([intervalRow], in: .leading)
        photoSection.orientation = .vertical; photoSection.spacing = 3
        photoSection.detachesHiddenViews = true

        // 操作行
        let actionRow = NSStackView(views: [hideBtn, quitBtn])
        actionRow.spacing = 8; actionRow.distribution = .fillEqually

        // 播放列表
        playlistScroll.documentView = playlistStack
        playlistScroll.heightAnchor.constraint(equalToConstant: 60).isActive = true
        playlistStack.widthAnchor.constraint(equalTo: playlistScroll.contentView.widthAnchor).isActive = true

        // 主 stack
        let mainStack = NSStackView(views: [
            modeSwitch,
            nameLabel,
            sep(),
            transportRow,
            sep(),
            videoSection,
            photoSection,
            actionRow,
            sep(),
            playlistLabel,
            playlistScroll,
            statusLabel
        ])
        mainStack.orientation = .vertical
        mainStack.spacing = 3
        mainStack.alignment = .leading
        mainStack.edgeInsets = NSEdgeInsets(top: 28, left: 12, bottom: 6, right: 12)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        cv.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: cv.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: cv.bottomAnchor)
        ])

        volumeSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10); l.textColor = .secondaryLabelColor
        return l
    }

    // MARK: - 按钮绑定

    private func setupActions() {
        modeSwitch.target = app; modeSwitch.action = #selector(AppDelegate.switchMediaMode(_:))

        prevBtn.target = app; prevBtn.action = #selector(AppDelegate.playPrev)
        playBtn.target = app; playBtn.action = #selector(AppDelegate.togglePause)
        nextBtn.target = app; nextBtn.action = #selector(AppDelegate.playNext)

        musicBtn.target = app; musicBtn.action = #selector(AppDelegate.toggleMute)
        volumeSlider.target = self; volumeSlider.action = #selector(volumeChanged(_:))

        modePop.target = self; modePop.action = #selector(modeChanged(_:))
        qualityPop.target = self; qualityPop.action = #selector(qualityChanged(_:))
        fpsPop.target = self; fpsPop.action = #selector(framerateChanged(_:))

        intervalPop.target = self; intervalPop.action = #selector(intervalChanged(_:))

        hideBtn.target = app; hideBtn.action = #selector(AppDelegate.toggleHidden)
        quitBtn.target = app; quitBtn.action = #selector(AppDelegate.stopAndQuit)
    }

    // MARK: - Action Handlers

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        let modes: [PlayMode] = [.single, .sequential, .shuffled]
        let newMode = modes[sender.indexOfSelectedItem]
        guard newMode != app.playlist.mode else { return }
        app.playlist.mode = newMode
        app.wallpaper.singleMode = app.playlist.isSingleMode
        app.replayCurrent()
        app.rebuildMenu()
        app.controlWin?.refresh()
    }

    @objc private func qualityChanged(_ sender: NSPopUpButton) {
        let q: VideoQuality = [.high, .original, .fourK][sender.indexOfSelectedItem]
        guard q != app.videoQuality else { return }
        app.videoQuality = q
        app.replayCurrent()
        app.rebuildMenu()
        app.controlWin?.refresh()
    }

    @objc private func framerateChanged(_ sender: NSPopUpButton) {
        let f: VideoFramerate = [.auto, .fps30, .fps60][sender.indexOfSelectedItem]
        guard f != app.wallpaper.framerate else { return }
        app.wallpaper.framerate = f
        app.replayCurrent()
        app.rebuildMenu()
        app.controlWin?.refresh()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        app.setWallpaperVolume(Float(sender.floatValue))
        app.controlWin?.refresh()
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        let val = intervalValues[sender.indexOfSelectedItem]
        app.photoInterval = val > 0 ? val : .infinity
        app.stopPhotoTimer()
        if app.currentMode == .photo && !app.wallpaper.isPaused && val > 0 {
            app.startPhotoTimer()
        }
    }

    // MARK: - 状态刷新

    func refresh() {
        let isVideo = app.currentMode == .video
        modeSwitch.selectedSegment = isVideo ? 0 : 1
        nameLabel.stringValue = app.playlist.name

        playBtn.title = app.wallpaper.isPaused ? "▶" : "⏸"
        hideBtn.title = app.wallpaper.isHidden ? "显示壁纸" : "隐藏壁纸"

        if app.wallpaper.isMuted || app.wallpaper.volume < 0.01 { musicBtn.title = "🔇" }
        else if app.wallpaper.volume < 0.5 { musicBtn.title = "🔉" }
        else { musicBtn.title = "🔊" }

        volumeSlider.floatValue = app.wallpaper.volume
        statusLabel.stringValue = app.adaptiveManager?.systemStatusText ?? ""

        // 切换视频/照片专属区域
        videoSection.isHidden = !isVideo
        photoSection.isHidden = isVideo

        // 视频设置
        let mi = app.playlist.mode == .single ? 0 : app.playlist.mode == .sequential ? 1 : 2
        if modePop.indexOfSelectedItem != mi { modePop.selectItem(at: mi) }
        let qi = app.videoQuality == .high ? 0 : app.videoQuality == .original ? 1 : 2
        if qualityPop.indexOfSelectedItem != qi { qualityPop.selectItem(at: qi) }
        let fi = app.wallpaper.framerate == .auto ? 0 : app.wallpaper.framerate == .fps30 ? 1 : 2
        if fpsPop.indexOfSelectedItem != fi { fpsPop.selectItem(at: fi) }

        // 照片间隔
        let intervalIdx = intervalValues.firstIndex(where: { $0 == app.photoInterval || ($0 == 0 && app.photoInterval.isInfinite) }) ?? 1
        if intervalPop.indexOfSelectedItem != intervalIdx { intervalPop.selectItem(at: intervalIdx) }

        // 调整面板尺寸
        let targetH = isVideo ? videoPanelHeight : photoPanelHeight
        let f = panel.frame
        if f.height != targetH {
            panel.setFrame(NSRect(x: f.minX, y: f.maxY - targetH, width: panelWidth, height: targetH), display: true, animate: true)
        }

        rebuildPlaylist()
    }

    // MARK: - 播放列表

    private func rebuildPlaylist() {
        for view in playlistStack.arrangedSubviews { view.removeFromSuperview() }
        let isVideo = app.currentMode == .video
        for (i, url) in app.playlist.videos.enumerated() {
            guard (isVideo && !isImageFile(url)) || (!isVideo && isImageFile(url)) else { continue }
            let cb = NSButton(title: url.lastPathComponent, target: self, action: #selector(togglePlaylistItem(_:)))
            cb.setButtonType(.switch)
            cb.controlSize = .small
            cb.font = .systemFont(ofSize: 10)
            cb.state = app.playlist.isEnabled(url) ? .on : .off
            cb.tag = i
            playlistStack.addArrangedSubview(cb)
        }
    }

    @objc private func togglePlaylistItem(_ sender: NSButton) {
        let url = app.playlist.videos[sender.tag]
        app.playlist.toggle(url)
        sender.state = app.playlist.isEnabled(url) ? .on : .off
        if !app.playlist.isEnabled(url) && app.playlist.current == url {
            app.playNext()
        }
        app.rebuildMenu()
    }

    // MARK: - 窗口管理

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        // 不调用 NSApp.activate，不抢其他 app 焦点
    }

    func hide() {
        panel.orderOut(nil)
    }

    func togglePanel() {
        isVisible ? hide() : show()
    }

    @objc func hidePanel() {
        hide()
    }

    func windowWillClose(_: Notification) {
        app.stopAndQuit()
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    let wallpaper = PlayerProxy()
    let playlist = PlaylistManager()
    let watcher = FolderWatcher()
    let photoWatcher = FolderWatcher()
    var statusItem: NSStatusItem?
    var controlWin: ControlWin?
    var converted: [URL: URL] = [:]
    var videoQuality: VideoQuality = .fourK
    var adaptiveManager: AdaptivePerformanceManager?
    var isInPowerSaver = false
    var testController: TestController?
    var currentMode: MediaMode = .video
    var photoInterval: TimeInterval = 5
    private var photoTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Ensure folders exist
        try? FileManager.default.createDirectory(at: videoFolderURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: videoSubfolderURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: photoSubfolderURL, withIntermediateDirectories: true)
        setupMenu(); setupControlWin()
        adaptiveManager = AdaptivePerformanceManager(wallpaper: wallpaper, app: self)
        // Load videos from folder
        let videos = scanVideoFolder()
        if !videos.isEmpty {
            playlist.set(videos)
            if let first = playlist.current { currentMode = isImageFile(first) ? .photo : .video }
            startCurrent()
            if currentMode == .photo { startPhotoTimer() }
        }
        else { controlWin?.refresh(); rebuildMenu() }
        // Watch folders for changes
        watcher.start(path: videoSubfolderURL.path) { [weak self] in self?.folderChanged() }
        photoWatcher.start(path: photoSubfolderURL.path) { [weak self] in self?.folderChanged() }
        // Auto-play on video end (sequential/shuffle mode)
        wallpaper.onVideoEnd = { [weak self] in self?.playNext() }
        // Show control window
        controlWin?.show()

        // Test mode
        if CommandLine.arguments.contains("--test") { setupTestMode() }
    }

    func applicationWillTerminate(_: Notification) { watcher.stop(); photoWatcher.stop(); for v in converted.values { try? FileManager.default.removeItem(at: v) }; wallpaper.cleanup() }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controlWin?.show()
        return false
    }

    // ---- Power Saver ----

    func enterPowerSaverMode() {
        guard !isInPowerSaver else { return }
        isInPowerSaver = true
        if videoQuality != .high {
            videoQuality = .high
            replayCurrent()
        }
    }

    func exitPowerSaverMode() {
        guard isInPowerSaver else { return }
        isInPowerSaver = false
    }

    // ---- Folder ----

    func folderChanged() {
        let videos = scanVideoFolder()
        let oldSet = Set(playlist.videos); let newSet = Set(videos)
        if oldSet == newSet { return } // no real change
        // Clean up stale converted files
        for (k, v) in converted where !newSet.contains(k) { try? FileManager.default.removeItem(at: v); converted[k] = nil }
        let wasEmpty = playlist.isEmpty
        playlist.set(videos)
        if wasEmpty && !videos.isEmpty { startCurrent() }
        else if !wasEmpty && videos.isEmpty { wallpaper.cleanup(); rebuildMenu(); controlWin?.refresh() }
        else { rebuildMenu(); controlWin?.refresh() }
    }

    @objc func openFolder() { NSWorkspace.shared.open(currentMode == .video ? videoSubfolderURL : photoSubfolderURL) }

    // ---- Playback ----

    func startCurrent() {
        guard let url = playlist.current else { return }
        rebuildMenu(); controlWin?.refresh()
        Task { await play(url: url, quality: videoQuality) }
    }

    func switchToVideo(at i: Int) {
        guard let url = playlist.jump(i: i) else { return }
        rebuildMenu(); controlWin?.refresh()
        Task { await play(url: url, quality: videoQuality) }
    }

    private func play(url: URL, quality: VideoQuality) async {
        await MainActor.run { wallpaper.singleMode = playlist.isSingleMode }
        if isImageFile(url) {
            await MainActor.run { wallpaper.displayImage(url: url) }
            return
        }
        if let c = converted[url] { await MainActor.run { wallpaper.switchVideo(url: c, quality: quality) }; return }
        let f = await processVideo(url: url, quality: quality)
        if f != url { converted[url] = f }
        await MainActor.run { wallpaper.switchVideo(url: f, quality: quality) }
    }

    func replayCurrent(quality: VideoQuality? = nil) {
        guard let u = playlist.current else { return }
        if let c = converted[u] { try? FileManager.default.removeItem(at: c); converted[u] = nil }
        Task { await play(url: u, quality: quality ?? videoQuality) }
    }

    func setupControlWin() { controlWin = ControlWin(app: self) }

    // ---- Playback Controls ----

    @objc func playNext() {
        guard playlist.count > 1 else { return }
        var attempts = 0
        repeat {
            if playlist.isSingleMode { _ = playlist.next() }
            else { guard playlist.next() != nil else { return } }
            attempts += 1
            if attempts > playlist.count { return }
        } while !isCurrentURLModeMatch()
        switchToVideo(at: playlist.index)
    }

    @objc func playPrev() {
        guard playlist.count > 1 else { return }
        var attempts = 0
        repeat {
            guard playlist.prev() != nil else { return }
            attempts += 1
            if attempts > playlist.count { return }
        } while !isCurrentURLModeMatch()
        switchToVideo(at: playlist.index)
    }

    private func isCurrentURLModeMatch() -> Bool {
        guard let url = playlist.current else { return false }
        return currentMode == .video ? !isImageFile(url) : isImageFile(url)
    }

    @objc func switchMediaMode(_ sender: NSSegmentedControl) {
        let newMode: MediaMode = sender.selectedSegment == 0 ? .video : .photo
        guard newMode != currentMode else { return }
        currentMode = newMode
        stopPhotoTimer()
        wallpaper.singleMode = newMode == .video && playlist.isSingleMode
        let match = playlist.videos.firstIndex { newMode == .photo ? isImageFile($0) : !isImageFile($0) }
        if let i = match, let url = playlist.jump(i: i) { Task { await play(url: url, quality: videoQuality) } }
        if newMode == .photo { startPhotoTimer() }
        controlWin?.refresh(); rebuildMenu()
    }

    func startPhotoTimer() {
        stopPhotoTimer()
        photoTimer = Timer.scheduledTimer(withTimeInterval: photoInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.playNext() }
        }
    }
    func stopPhotoTimer() {
        photoTimer?.invalidate()
        photoTimer = nil
    }

    @objc func togglePause() {
        wallpaper.togglePause()
        if currentMode == .photo {
            if wallpaper.isPaused { stopPhotoTimer() } else { startPhotoTimer() }
        }
        rebuildMenu(); controlWin?.refresh()
    }
    @objc func toggleMute() { wallpaper.toggleMute(); rebuildMenu(); controlWin?.refresh() }
    @objc func setWallpaperVolume(_ v: Float) { wallpaper.setVolume(v); rebuildMenu(); controlWin?.refresh() }
    @objc func toggleHidden() { wallpaper.toggleHidden(); rebuildMenu(); controlWin?.refresh() }
    @objc func toggleControlPanel() { controlWin?.togglePanel(); rebuildMenu() }
    @objc func toggleQuality() {
        videoQuality = videoQuality == .high ? .original : videoQuality == .original ? .fourK : .high
        replayCurrent(); rebuildMenu(); controlWin?.refresh()
    }

    // ---- Menu ----

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem?.button {
            if #available(macOS 11.0, *) { b.image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "动态壁纸") }
        }
        rebuildMenu()
    }

    func rebuildMenu() {
        let m = NSMenu()
        let h = NSMenuItem(title: "当前: \(playlist.name)", action: nil, keyEquivalent: ""); h.isEnabled = false
        m.addItem(h); m.addItem(.separator())
        let ni = m.addItem(withTitle: "下一个", action: #selector(playNext), keyEquivalent: "n")
        ni.keyEquivalentModifierMask = [.command, .shift]
        let bi = m.addItem(withTitle: "上一个", action: #selector(playPrev), keyEquivalent: "b")
        bi.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(withTitle: "画质: \(videoQuality.rawValue)", action: #selector(toggleQuality), keyEquivalent: "")
        m.addItem(withTitle: wallpaper.isPaused ? "继续" : "暂停", action: #selector(togglePause), keyEquivalent: " ")
        m.addItem(withTitle: wallpaper.isMuted ? "🔇 取消静音" : "🔊 音频", action: #selector(toggleMute), keyEquivalent: "")
        let hi = m.addItem(withTitle: wallpaper.isHidden ? "显示壁纸" : "隐藏壁纸", action: #selector(toggleHidden), keyEquivalent: "h")
        hi.keyEquivalentModifierMask = [.command, .shift]
        let pi = m.addItem(withTitle: (controlWin?.isVisible ?? false) ? "隐藏面板" : "显示面板", action: #selector(toggleControlPanel), keyEquivalent: "p")
        pi.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(.separator())
        let ms = NSMenuItem(title: "播放模式", action: nil, keyEquivalent: "")
        let mm = NSMenu()
        for pm in [PlayMode.single, .sequential, .shuffled] {
            let i = NSMenuItem(title: pm.rawValue, action: #selector(setMode(_:)), keyEquivalent: ""); i.tag = pm == .single ? 0 : pm == .sequential ? 1 : 2
            if playlist.mode == pm { i.state = .on }; mm.addItem(i)
        }
        ms.submenu = mm; m.addItem(ms)
        // Playlist submenu with checkmarks
        let ps = NSMenuItem(title: "播放列表", action: nil, keyEquivalent: "")
        let pmu = NSMenu()
        for (i, url) in playlist.videos.enumerated() {
            let ii = NSMenuItem(title: url.lastPathComponent, action: #selector(toggleVideo(_:)), keyEquivalent: "")
            ii.tag = i; ii.state = playlist.isEnabled(url) ? .on : .off
            pmu.addItem(ii)
        }
        ps.submenu = pmu; m.addItem(ps); m.addItem(.separator())
        if let am = adaptiveManager {
            for item in am.statusItems { m.addItem(item) }
            m.addItem(.separator())
        }
        m.addItem(withTitle: "📂 打开素材文件夹", action: #selector(openFolder), keyEquivalent: "")
        if let tc = testController {
            m.addItem(.separator())
            let ti = NSMenuItem(title: "🧪 测试 #\(tc.cycleCount) | \(memoryString())", action: nil, keyEquivalent: "")
            ti.isEnabled = false; m.addItem(ti)
        }
        m.addItem(.separator())
        m.addItem(withTitle: "退出", action: #selector(stopAndQuit), keyEquivalent: "q")
        statusItem?.menu = m
    }

    @objc func setMode(_ s: NSMenuItem) {
        playlist.mode = [.single, .sequential, .shuffled][s.tag]
        wallpaper.singleMode = playlist.isSingleMode
        replayCurrent(); rebuildMenu(); controlWin?.refresh()
    }

    @objc func toggleVideo(_ s: NSMenuItem) {
        let url = playlist.videos[s.tag]
        playlist.toggle(url)
        // If current video was just disabled, skip to next
        if !playlist.isEnabled(url) && playlist.current == url { playNext() }
        rebuildMenu(); controlWin?.refresh()
    }

    @objc func stopAndQuit() { wallpaper.cleanup(); controlWin?.hide(); NSApp.terminate(nil) }

    // ---- Test Mode ----

    func setupTestMode() {
        let tc = TestController(app: self)
        testController = tc
        tc.start()
    }
}

// MARK: - Entry Point
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
