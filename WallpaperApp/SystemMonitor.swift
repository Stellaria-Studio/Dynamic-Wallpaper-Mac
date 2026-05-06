import Cocoa
import IOKit.ps

// MARK: - PowerMonitor

class PowerMonitor {
    private(set) var isOnBattery = false
    private var source: CFRunLoopSource?
    var onPowerSourceChange: ((_ onBattery: Bool) -> Void)?

    init() {
        refresh()
        setupNotification()
    }

    private func refresh() {
        let raw = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? ?? ""
        isOnBattery = raw == "Batt Power"
    }

    private func setupNotification() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let m = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            m.refresh()
            m.onPowerSourceChange?(m.isOnBattery)
        }
        guard let ls = IOPSNotificationCreateRunLoopSource(callback, ctx)?.takeRetainedValue() else { return }
        source = ls
        CFRunLoopAddSource(CFRunLoopGetMain(), ls, .commonModes)
    }

    deinit {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
    }
}

// MARK: - ThermalMonitor

class ThermalMonitor {
    enum State: String { case nominal = "正常", fair = "较高", serious = "过高", critical = "临界" }
    private(set) var state: State = .nominal
    var onThermalStateChange: ((State) -> Void)?

    init() {
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFromNotif), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    private func refresh() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  state = .nominal
        case .fair:     state = .fair
        case .serious:  state = .serious
        case .critical: state = .critical
        @unknown default: state = .nominal
        }
    }

    @objc private func refreshFromNotif() { refresh(); onThermalStateChange?(state) }
    deinit { NotificationCenter.default.removeObserver(self) }
}

// MARK: - SleepWakeHandler

class SleepWakeHandler {
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func willSleep(_: Notification) { onWillSleep?() }
    @objc private func didWake(_: Notification) { onDidWake?() }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
}

// MARK: - FullScreenDetector

class FullScreenDetector: NSObject {
    private(set) var hasFullScreenApp = false
    var onFullScreenChange: ((Bool) -> Void)?

    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        perform(#selector(check), with: nil as Any?, afterDelay: 0.5)
    }

    @objc private func appActivated() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(check), object: nil)
        perform(#selector(check), with: nil as Any?, afterDelay: 0.3)
    }

    @objc private func check() {
        let prev = hasFullScreenApp
        hasFullScreenApp = scan()
        if prev != hasFullScreenApp { onFullScreenChange?(hasFullScreenApp) }
    }

    private func scan() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        let ourPID = ProcessInfo.processInfo.processIdentifier
        for w in windows {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != ourPID,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = w[kCGWindowLayer as String] as? Int32, layer == 0 else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                               width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            for screen in NSScreen.screens where screen.frame.equalTo(frame) {
                return true
            }
        }
        return false
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }
}

// MARK: - EnvironmentMonitor

class EnvironmentMonitor: NSObject {
    var onActiveSpaceChange: (() -> Void)?
    var onAppearanceChange: ((NSAppearance?) -> Void)?

    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSApp.addObserver(self, forKeyPath: "effectiveAppearance", options: .new, context: nil)
    }

    @objc private func spaceChanged() { onActiveSpaceChange?() }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "effectiveAppearance" { onAppearanceChange?(NSApp.effectiveAppearance) }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NSApp.removeObserver(self, forKeyPath: "effectiveAppearance")
    }
}

// MARK: - FocusDetector

class FocusDetector {
    private(set) var isInFocusMode = false
    var onFocusChange: ((Bool) -> Void)?
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let prev = self.isInFocusMode
            self.refresh()
            if prev != self.isInFocusMode { self.onFocusChange?(self.isInFocusMode) }
        }
    }

    private func refresh() {
        let prefs = UserDefaults.standard.persistentDomain(forName: "com.apple.notificationcenterui")
        isInFocusMode = prefs?["doNotDisturb"] as? Bool ?? false
    }

    deinit { timer?.invalidate() }
}
