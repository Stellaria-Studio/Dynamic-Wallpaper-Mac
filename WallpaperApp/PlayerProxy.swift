import Cocoa

/// Proxy that communicates with the WallpaperPlayer helper process via stdin/stdout pipes.
/// Provides the same API as WallpaperController but delegates all AVFoundation work to the helper.
class PlayerProxy {
    // MARK: - Properties (matching WallpaperController interface)

    private(set) var isUserPaused = false
    private(set) var isPerformancePaused = false
    var isPaused: Bool { isUserPaused || isPerformancePaused }
    private(set) var isHidden = false
    private(set) var isMuted = true
    var volume: Float = 1.0

    var quality: VideoQuality = .fourK
    var framerate: VideoFramerate = .auto
    var singleMode = false
    var onVideoEnd: (() -> Void)?

    // Memory stats from helper
    private(set) var currentMemory: Double = 0
    private(set) var peakMemory: Double = 0

    // Current video for state restoration
    private var currentURL: URL?

    // MARK: - Process Management

    private var helper: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var eventBuffer = ""
    private var isRestoring = false
    private var needsRestore = false

    init() {
        launchHelper()
    }

    deinit {
        cleanup()
    }

    // MARK: - Helper Path

    private func helperExecPath() -> String? {
        let bundle = Bundle.main.bundleURL
        // Bundled in Resources
        let bundled = bundle.appendingPathComponent("Contents/Resources/WallpaperPlayer.app/Contents/MacOS/WallpaperPlayer")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        // Sibling app (dev build)
        let sibling = bundle.deletingLastPathComponent().appendingPathComponent("WallpaperPlayer.app/Contents/MacOS/WallpaperPlayer")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling.path }
        // Raw binary in source directory
        let dev = bundle.deletingLastPathComponent().appendingPathComponent("WallpaperPlayer/WallpaperPlayer")
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev.path }
        return nil
    }

    // MARK: - Launch & Restart

    private func launchHelper() {
        guard let path = helperExecPath() else {
            print("[PlayerProxy] ❌ WallpaperPlayer not found")
            return
        }

        // Clean up old pipe handler
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        eventBuffer = ""

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)

        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                DispatchQueue.main.async { self?.onHelperExit() }
                return
            }
            self?.onHelperOutput(data)
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                print("[PlayerProxy] Helper exited (code: \(proc.terminationStatus))")
                self?.onHelperExit()
            }
        }

        do {
            try p.run()
            helper = p
            inputPipe = inPipe
            outputPipe = outPipe
            print("[PlayerProxy] ✅ Helper launched (PID: \(p.processIdentifier))")
        } catch {
            print("[PlayerProxy] ❌ Launch failed: \(error)")
        }
    }

    private func onHelperExit() {
        guard helper != nil else { return }
        helper = nil
        inputPipe = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil

        // Mark that helper crashed — need state restore on next launch
        needsRestore = true

        // Auto-restart after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.launchHelper()
        }
    }

    // MARK: - Event Parsing

    private func onHelperOutput(_ data: Data) {
        eventBuffer += String(data: data, encoding: .utf8) ?? ""
        while let nl = eventBuffer.firstIndex(of: "\n") {
            let line = String(eventBuffer[..<nl])
            eventBuffer = String(eventBuffer[eventBuffer.index(after: nl)...])
            if !line.isEmpty {
                DispatchQueue.main.async { self.dispatchEvent(line) }
            }
        }
    }

    private func dispatchEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }

        switch event {
        case "ready":
            print("[PlayerProxy] Helper ready")
            isRestoring = false
            if needsRestore && currentURL != nil {
                needsRestore = false
                sendRestore()
            }

        case "videoEnded":
            onVideoEnd?()

        case "status", "playing":
            if let urlStr = obj["url"] as? String { currentURL = URL(fileURLWithPath: urlStr) }
            if let paused = obj["userPaused"] as? Bool { isUserPaused = paused }
            if let perfPaused = obj["perfPaused"] as? Bool { isPerformancePaused = perfPaused }
            if let muted = obj["muted"] as? Bool { isMuted = muted }
            if let hidden = obj["hidden"] as? Bool { isHidden = hidden }
            if let v = obj["volume"] as? Double { volume = Float(v) }

        case "paused":
            if let v = obj["value"] as? Bool { isUserPaused = v }

        case "muted":
            if let v = obj["value"] as? Bool { isMuted = v }

        case "hidden":
            if let v = obj["value"] as? Bool { isHidden = v }

        case "mem":
            if let mb = obj["mb"] as? Double {
                currentMemory = mb
                peakMemory = max(peakMemory, mb)
            }

        case "error":
            if let msg = obj["message"] as? String {
                print("[PlayerProxy] ⚠️ Helper error: \(msg)")
            }

        default:
            break
        }
    }

    // MARK: - Send Commands

    private func sendCommand(_ cmd: [String: Any]) {
        guard let pipe = inputPipe, let h = helper, h.isRunning,
              let data = try? JSONSerialization.data(withJSONObject: cmd) else { return }
        pipe.fileHandleForWriting.write(data)
        pipe.fileHandleForWriting.write("\n".data(using: .utf8)!)
    }

    private func sendRestore() {
        guard let url = currentURL else { return }
        isRestoring = true
        let cmd: [String: Any] = [
            "cmd": "start",
            "url": url.path,
            "quality": quality.rawValue,
            "muted": isMuted,
            "singleMode": singleMode
        ]
        sendCommand(cmd)
        if isHidden { sendCommand(["cmd": "setHidden", "value": true]) }
        if isUserPaused { sendCommand(["cmd": "setPaused", "value": true]) }
        if isPerformancePaused { sendCommand(["cmd": "setPerformancePaused", "value": true]) }
        if volume < 1.0 { sendCommand(["cmd": "setVolume", "value": volume]) }
    }

    // MARK: - Public API (matches WallpaperController)

    func start(url: URL, quality q: VideoQuality = .high) {
        quality = q
        currentURL = url
        sendCommand(["cmd": "start", "url": url.path, "quality": q.rawValue,
                     "muted": isMuted, "singleMode": singleMode])
    }

    func switchVideo(url: URL, quality q: VideoQuality? = nil) {
        if let q = q { quality = q }
        currentURL = url
        var cmd: [String: Any] = ["cmd": "switchVideo", "url": url.path]
        if let q = q { cmd["quality"] = q.rawValue }
        cmd["singleMode"] = singleMode
        sendCommand(cmd)
    }

    func displayImage(url: URL) {
        currentURL = url
        sendCommand(["cmd": "showImage", "url": url.path])
    }

    func togglePause() {
        isUserPaused.toggle()
        sendCommand(["cmd": "setPaused", "value": isUserPaused])
    }

    func setPerformancePaused(_ paused: Bool) {
        isPerformancePaused = paused
        sendCommand(["cmd": "setPerformancePaused", "value": paused])
    }

    func forcePause() {
        sendCommand(["cmd": "forcePause"])
    }

    func resumeIfNotPaused() {
        sendCommand(["cmd": "resumeIfNotPaused"])
    }

    func setHidden(_ h: Bool) {
        isHidden = h
        sendCommand(["cmd": "setHidden", "value": h])
    }

    func toggleHidden() {
        isHidden.toggle()
        sendCommand(["cmd": "setHidden", "value": isHidden])
    }

    func toggleMute() {
        isMuted.toggle()
        sendCommand(["cmd": "setMuted", "value": isMuted])
    }

    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        sendCommand(["cmd": "setVolume", "value": volume])
    }

    func cleanup() {
        sendCommand(["cmd": "cleanup"])
        helper?.terminate()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        helper = nil
        inputPipe = nil
        outputPipe = nil
    }
}
