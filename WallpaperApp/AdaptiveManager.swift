import Cocoa

class AdaptivePerformanceManager {
    let power = PowerMonitor()
    let thermal = ThermalMonitor()
    let sleep = SleepWakeHandler()
    let fullScreen = FullScreenDetector()
    let env = EnvironmentMonitor()
    let focus = FocusDetector()

    weak var wallpaper: PlayerProxy?
    weak var app: AppDelegate?

    private var pausedForThermal = false
    private var pausedForFullScreen = false

    init(wallpaper: PlayerProxy, app: AppDelegate) {
        self.wallpaper = wallpaper
        self.app = app
        wire()
    }

    private func wire() {
        power.onPowerSourceChange = { [weak self] onBattery in
            guard let self, let ad = self.app else { return }
            if onBattery { ad.enterPowerSaverMode() }
            else { ad.exitPowerSaverMode() }
            ad.rebuildMenu()
            ad.controlWin?.refresh()
        }

        thermal.onThermalStateChange = { [weak self] state in
            guard let self, let w = self.wallpaper else { return }
            switch state {
            case .serious, .critical:
                guard !w.isPerformancePaused else { return }
                w.setPerformancePaused(true)
                self.pausedForThermal = true
            case .fair, .nominal:
                guard self.pausedForThermal else { return }
                w.setPerformancePaused(false)
                self.pausedForThermal = false
            }
            self.app?.rebuildMenu()
            self.app?.controlWin?.refresh()
        }

        sleep.onWillSleep = { [weak self] in self?.wallpaper?.forcePause() }
        sleep.onDidWake = { [weak self] in self?.wallpaper?.resumeIfNotPaused() }

        fullScreen.onFullScreenChange = { [weak self] fs in
            guard let self, let w = self.wallpaper else { return }
            if fs { w.setPerformancePaused(true); self.pausedForFullScreen = true }
            else if self.pausedForFullScreen { w.setPerformancePaused(false); self.pausedForFullScreen = false }
            self.app?.rebuildMenu()
            self.app?.controlWin?.refresh()
        }

        // Panel inherits appearance automatically; no-op needed
    }

    var statusItems: [NSMenuItem] {
        var items: [NSMenuItem] = []
        let bat = NSMenuItem(title: power.isOnBattery ? "🔋 节能" : "🔌 外接电源", action: nil, keyEquivalent: "")
        bat.isEnabled = false; items.append(bat)
        let therm = NSMenuItem(title: "🌡 温度\(thermal.state.rawValue)", action: nil, keyEquivalent: "")
        therm.isEnabled = false; items.append(therm)
        if pausedForFullScreen || pausedForThermal {
            let p = NSMenuItem(title: "⏸ 已暂停", action: nil, keyEquivalent: "")
            p.isEnabled = false; items.append(p)
        }
        return items
    }

    var systemStatusText: String {
        let p = power.isOnBattery ? "节能" : "外接电源"
        let t = "🌡\(thermal.state.rawValue)"
        let s = (pausedForFullScreen || pausedForThermal) ? " ⏸已暂停" : ""
        return "\(p) | \(t)\(s)"
    }

    deinit {
        power.onPowerSourceChange = nil
        thermal.onThermalStateChange = nil
        sleep.onWillSleep = nil; sleep.onDidWake = nil
        fullScreen.onFullScreenChange = nil
        env.onAppearanceChange = nil
    }
}
