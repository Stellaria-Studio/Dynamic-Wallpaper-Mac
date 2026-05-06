import Cocoa
import Foundation
import UniformTypeIdentifiers
import ScreenCaptureKit
import CoreImage

// MARK: - Memory Monitor

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

func memoryString() -> String {
    let mb = Double(getMemoryUsage()) / 1048576.0
    return String(format: "%.1f MB", mb)
}

// MARK: - Screen Capture + 黑屏检测 (使用 ScreenCaptureKit)

class ScreenCapture: NSObject {
    private let samplePoints: [CGPoint]
    private let blackThreshold: Float = 0.08  // 亮度 < 8% 视为黑屏

    /// 日志目录（与 tester 共享）
    private var screenshotDir: URL

    // 截屏状态
    private var stream: SCStream?
    private var captureContinuation: CheckedContinuation<CGImage, any Error>?

    override init() {
        let logDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/wallpaper_test/screenshots")
        screenshotDir = logDir
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        // 采样 9 个点：3×3 网格（避开边缘）
        samplePoints = [
            CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.8, y: 0.2),
            CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.8, y: 0.5),
            CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.5, y: 0.8), CGPoint(x: 0.8, y: 0.8),
        ]
    }

    /// 异步截取主屏幕画面
    func captureMainDisplay() async -> CGImage? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // 降采样以提升速度，黑屏检测不需要全分辨率
            config.width = 960
            config.height = 540
            config.showsCursor = false
            config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
            config.capturesAudio = false

            return try await withCheckedThrowingContinuation { continuation in
                self.captureContinuation = continuation
                let s = SCStream(filter: filter, configuration: config, delegate: nil)
                self.stream = s
                do {
                    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                    s.startCapture()
                } catch {
                    continuation.resume(throwing: error)
                    self.captureContinuation = nil
                }
            }
        } catch {
            return nil
        }
    }

    /// 分析画面亮度，返回平均亮度 (0~1)
    func measureBrightness(in image: CGImage) -> Float {
        let width = image.width
        let height = image.height

        guard let dataProvider = image.dataProvider,
              let pixelData = dataProvider.data,
              let data = CFDataGetBytePtr(pixelData) else { return 1.0 }
        let bytesPerRow = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8

        var totalBrightness: Float = 0
        for pt in samplePoints {
            let x = Int(CGFloat(width) * pt.x)
            let y = Int(CGFloat(height) * pt.y)
            let offset = y * bytesPerRow + x * bpp
            let r = Float(data[offset])
            let g = Float(data[offset + 1])
            let b = Float(data[offset + 2])
            let brightness = (r + g + b) / (3.0 * 255.0)
            totalBrightness += brightness
        }
        return totalBrightness / Float(samplePoints.count)
    }

    /// 判断是否黑屏
    func isBlackScreen(_ brightness: Float) -> Bool {
        brightness < blackThreshold
    }

    /// 保存截图到磁盘，返回文件路径
    @discardableResult
    func saveScreenshot(_ image: CGImage, name: String) -> String? {
        let url = screenshotDir.appendingPathComponent("\(name).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return url.path
    }

    /// 清理旧截图
    func cleanOldScreenshots(olderThan: TimeInterval = 86400) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: screenshotDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-olderThan)
        for f in files {
            if let attrs = try? f.resourceValues(forKeys: [.creationDateKey]), let d = attrs.creationDate, d < cutoff {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}

// MARK: - SCStreamOutput

extension ScreenCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let imageBuffer = sampleBuffer.imageBuffer,
              let continuation = captureContinuation else { return }

        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            continuation.resume(throwing: NSError(domain: "capture", code: -1))
            captureContinuation = nil
            return
        }

        continuation.resume(returning: cgImage)
        captureContinuation = nil
        stream.stopCapture()
        self.stream = nil
    }
}

// MARK: - TestController

class TestController {
    enum Scenario: String {
        case rapid = "rapid"
        case mixed = "mixed"
        case longRun = "long"
        case fullStress = "stress"
    }

    unowned let app: AppDelegate
    private var timer: Timer?
    private(set) var cycleCount = 0
    private(set) var startTime: Date?
    private var sessionTag: String = ""
    private var logFile: FileHandle?
    private var peakMemory: UInt64 = 0
    private var blackScreenCount = 0
    private var lastBrightness: Float = 1.0

    private(set) var scenario: Scenario = .mixed
    private(set) var interval: TimeInterval = 5.0
    private(set) var maxCycles: Int = 0
    private var durationMinutes: Double = 0

    private(set) var checkBlackScreen = false
    private var screenshot: ScreenCapture?

    init(app: AppDelegate) {
        self.app = app
        parseArguments()
        if checkBlackScreen {
            screenshot = ScreenCapture()
            screenshot?.cleanOldScreenshots()
        }
    }

    deinit {
        timer?.invalidate()
        closeLog()
    }

    private func parseArguments() {
        let args = CommandLine.arguments
        for i in 0..<args.count {
            switch args[i] {
            case "--scenario":
                if i+1 < args.count, let s = Scenario(rawValue: args[i+1]) { scenario = s }
            case "--interval":
                if i+1 < args.count, let v = TimeInterval(args[i+1]) { interval = max(v, 0.5) }
            case "--max":
                if i+1 < args.count, let v = Int(args[i+1]) { maxCycles = v }
            case "--duration":
                if i+1 < args.count, let v = Double(args[i+1]) { durationMinutes = v }
            case "--check-black":
                checkBlackScreen = true
            default: break
        }
    }
    }

    func start() {
        // Calculate maxCycles from duration if specified
        if durationMinutes > 0 {
            let totalSec = durationMinutes * 60
            maxCycles = Int(totalSec / interval)
    }

        startTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        sessionTag = formatter.string(from: startTime!)
        setupLogging()

        let opDesc: String
        switch scenario {
        case .rapid: opDesc = "rapid_switch(\(Int(interval))s)"
        case .mixed: opDesc = "mixed_ops(\(Int(interval))s)"
        case .longRun: opDesc = "long_run(\(Int(interval))s)"
        case .fullStress: opDesc = "full_stress(\(Int(interval))s)"
        }

        let limitDesc = maxCycles > 0 ? "max=\(maxCycles)" : "unlimited"
        writeLog("=== TEST START [\(opDesc) \(limitDesc)] ===")
        writeLog("memory: \(memoryString())")

        timer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(onTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)

        app.rebuildMenu()
    }

    func stop() {
        timer?.invalidate()
        timer = nil

        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let mem = getMemoryUsage()
        peakMemory = max(peakMemory, mem)

        writeLog("")
        writeLog("=== TEST REPORT ===")
        writeLog("Duration: \(formatDuration(duration))")
        writeLog("Cycles: \(cycleCount)")
        writeLog("Peak Memory: \(formatBytes(peakMemory))")
        writeLog("Final Memory: \(formatBytes(mem))")
        if checkBlackScreen {
            writeLog("Brightness: \(String(format: "%.2f", lastBrightness))")
            writeLog("Black Screen Events: \(blackScreenCount)")
        }
        writeLog("Status: COMPLETED")
        writeLog("===================")

        closeLog()
    }

    @objc private func onTick() {
        guard maxCycles == 0 || cycleCount < maxCycles else {
            stop()
            return
        }

        cycleCount += 1

        switch scenario {
        case .rapid: doRapidTick()
        case .mixed: doMixedTick()
        case .longRun: doLongRunTick()
        case .fullStress: doStressTick()
        }

        if cycleCount % 5 == 0 {
            writeLog("memory: \(memoryString())")
        }

        // 黑屏检测：每次操作后延迟采样（给渲染管线时间输出画面）
        if checkBlackScreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.checkScreen()
            }
        }

        app.rebuildMenu()
    }

    /// 截屏分析：检测黑屏并记录
    private func checkScreen() {
        guard let cap = screenshot else { return }
        guard needsCheck else { return }

        Task { @MainActor in
            guard let image = await cap.captureMainDisplay() else { return }
            let brightness = cap.measureBrightness(in: image)
            lastBrightness = brightness

            if cap.isBlackScreen(brightness) {
                blackScreenCount += 1
                let screenshotPath = cap.saveScreenshot(image, name: "black_\(sessionTag)_#\(cycleCount)")
                writeLog("⚠️ BLACK SCREEN #\(blackScreenCount) brightness=\(String(format: "%.3f", brightness)) saved=\(screenshotPath ?? "?")")
            } else if cycleCount % 5 == 0 {
                writeLog("screen: brightness=\(String(format: "%.2f", brightness))")
            }
        }
    }

    /// 采样频率控制：两次采样之间至少间隔 0.3s
    private var lastCheckTime: Date = .distantPast
    private var needsCheck: Bool {
        let now = Date()
        guard now.timeIntervalSince(lastCheckTime) > 0.3 else { return false }
        lastCheckTime = now
        return true
    }

    // MARK: - Scenario Ticks

    private var qualityCycle: Int = 0
    private var modeCycle: Int = 0

    private func doRapidTick() {
        app.playNext()
        writeLog("[#\(cycleCount)] switch: \(app.playlist.name)")

        if cycleCount % 5 == 0 {
            let qualities: [VideoQuality] = [.high, .original, .fourK]
            qualityCycle = (qualityCycle + 1) % qualities.count
            app.videoQuality = qualities[qualityCycle]
            writeLog("[#\(cycleCount)] quality: \(qualities[qualityCycle].rawValue)")
        }
    }

    private func doMixedTick() {
        let op = cycleCount % 5
        switch op {
        case 0:
            app.playNext()
            writeLog("[#\(cycleCount)] switch: \(app.playlist.name)")
        case 1:
            let qualities: [VideoQuality] = [.high, .original, .fourK]
            qualityCycle = (qualityCycle + 1) % qualities.count
            app.videoQuality = qualities[qualityCycle]
            app.replayCurrent()
            writeLog("[#\(cycleCount)] quality: \(qualities[qualityCycle].rawValue)")
        case 2:
            app.wallpaper.toggleMute()
            writeLog("[#\(cycleCount)] mute: \(app.wallpaper.isMuted)")
        case 3:
            let modes: [PlayMode] = [.single, .sequential, .shuffled]
            modeCycle = (modeCycle + 1) % modes.count
            app.playlist.mode = modes[modeCycle]
            app.wallpaper.singleMode = app.playlist.isSingleMode
            app.replayCurrent()
            writeLog("[#\(cycleCount)] mode: \(modes[modeCycle].rawValue)")
        case 4:
            if !app.playlist.videos.isEmpty {
                let idx = cycleCount % app.playlist.videos.count
                let url = app.playlist.videos[idx]
                app.playlist.toggle(url)
                writeLog("[#\(cycleCount)] toggle: \(url.lastPathComponent)")
            }
        default: break
        }
    }

    private func doLongRunTick() {
        app.playNext()
        let mem = getMemoryUsage()
        peakMemory = max(peakMemory, mem)
        writeLog("[#\(cycleCount)] switch: \(app.playlist.name) | peak: \(formatBytes(peakMemory))")
    }

    private func doStressTick() {
        app.playNext()

        if cycleCount % 3 == 0 {
            let qualities: [VideoQuality] = [.high, .original, .fourK]
            qualityCycle = (qualityCycle + 1) % qualities.count
            app.videoQuality = qualities[qualityCycle]

            if cycleCount % 6 == 0 {
                let modes: [PlayMode] = [.single, .sequential, .shuffled]
                modeCycle = (modeCycle + 1) % modes.count
                app.playlist.mode = modes[modeCycle]
                app.wallpaper.singleMode = app.playlist.isSingleMode
            }
        }

        let mem = getMemoryUsage()
        peakMemory = max(peakMemory, mem)
    }

    // MARK: - Logging

    private func setupLogging() {
        let logDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/wallpaper_test")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let logURL = logDir.appendingPathComponent("test_\(timestamp).log")

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logFile = try? FileHandle(forWritingTo: logURL)

        print("📝 Log: \(logURL.path)")
    }

    private func writeLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"

        print(line, terminator: "")
        fflush(stdout)

        if let data = line.data(using: .utf8) {
            logFile?.write(data)
        }
    }

    private func closeLog() {
        logFile?.closeFile()
        logFile = nil
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSec = Int(interval)
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1048576.0
        return String(format: "%.1f MB", mb)
    }
}
