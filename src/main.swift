import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sensors = Sensors()
    private let model = VitalsModel()
    private let popover = NSPopover()

    private let queue = DispatchQueue(label: "vitals.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tick = 0

    private let bar = BarView()
    private var snap = Snapshot()
    private var history: [Double] = []
    private var metrics = Metric.enabled
    private var lastSignature = ""

    // Tier intervals in seconds, chosen from measured cost per source rather than by feel.
    // Held as elapsed-time checks so they stay correct when the refresh rate changes.
    private let historyLength = 60
    private let mediumTier = 5.0    // temperature, power — ~680us a sample
    private let slowTier = 30.0     // GPU, battery, fan — ~2.5ms a sample
    private let diskTier = 300.0    // disk capacity — ~5.8ms a sample, and it barely moves
    private var lastMedium = 0.0, lastSlow = 0.0, lastDisk = 0.0

    /// Seconds between refreshes. The UI update costs far more than reading the sensors,
    /// so this is the main lever on the app's total footprint.
    static var interval: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "interval")
            return v >= 1 ? v : 2
        }
        set { UserDefaults.standard.set(newValue, forKey: "interval") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            bar.frame = NSRect(x: 0, y: 0, width: 1, height: Bar.height)
            bar.autoresizingMask = [.width, .height]
            button.addSubview(bar)
        }
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)

        popover.behavior = .transient

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(pause), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(resume), name: NSWorkspace.didWakeNotification, object: nil)

        sampleAll()
        start()
    }

    // MARK: sampling

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway lets the OS coalesce our wakeups with others — meaningful on battery.
        let every = AppDelegate.interval
        // Generous leeway lets the OS coalesce our wakeups with others.
        t.schedule(deadline: .now() + every, repeating: every, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    @objc private func pause() { timer?.suspend() }

    @objc private func resume() {
        timer?.resume()
        queue.async { [weak self] in self?.sampleAll() }
    }

    /// Cheap sources every refresh; the costlier ones ride their own elapsed-time tiers.
    private func sample() {
        tick += 1
        readFast()
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMedium >= mediumTier { lastMedium = now; readMedium() }
        if now - lastSlow >= slowTier { lastSlow = now; readSlow() }
        if now - lastDisk >= diskTier { lastDisk = now; readDisk() }
        publish()
    }

    private func sampleAll() {
        let now = CFAbsoluteTimeGetCurrent()
        lastMedium = now; lastSlow = now; lastDisk = now
        readFast(); readMedium(); readSlow(); readDisk(); publish()
    }

    private func readFast() {
        let cores = sensors.cpuLoad()
        if !cores.isEmpty {
            snap.perCore = cores
            snap.cpu = cores.reduce(0, +) / Double(cores.count)
            let e = cores.prefix(sensors.eCount)
            let p = cores.dropFirst(sensors.eCount)
            snap.eCore = e.isEmpty ? 0 : e.reduce(0, +) / Double(e.count)
            snap.pCore = p.isEmpty ? 0 : p.reduce(0, +) / Double(p.count)

            history.append(snap.cpu)
            if history.count > historyLength { history.removeFirst(history.count - historyLength) }
        }
        let m = sensors.memory()
        snap.ramPct = m.pct; snap.ramUsedGB = m.usedGB; snap.ramTotalGB = m.totalGB
        snap.swapGB = m.swapGB; snap.pressure = m.pressure
    }

    private func readMedium() {
        snap.temp = sensors.cpuTemp()
        snap.watts = sensors.power()
    }

    /// Disk capacity is by far the costliest source and the slowest to change, so it
    /// gets its own very slow tier instead of riding along with the others.
    private func readDisk() {
        let d = sensors.disk()
        snap.diskPct = d.pct; snap.diskFreeGB = d.freeGB; snap.diskTotalGB = d.totalGB
    }

    private func readSlow() {
        snap.fan = sensors.fanRPM()
        snap.gpu = sensors.gpuUsage()
        snap.battTemp = sensors.batteryTemp()
        let b = sensors.battery()
        snap.battPct = b.pct; snap.battHealth = b.health; snap.battCycles = b.cycles
        snap.charging = b.charging; snap.timeLeft = b.timeLeft
    }

    private func publish() {
        let s = snap, h = history, ms = metrics
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.popover.isShown {
                self.model.snap = s
                self.model.history = h
            }
            self.redrawIfChanged(s, h, ms)
        }
    }

    /// Re-renders only when something actually visible changed.
    private func redrawIfChanged(_ s: Snapshot, _ h: [Double], _ ms: [Metric]) {
        var sig = ms.map(\.rawValue).joined(separator: ",")
        sig += "|\(Int(s.ramPct))|\(Int(s.diskPct))|\(Int(s.temp))|\(Int(s.watts * 10))"
        sig += "|\(Int(s.gpu))|\(Int(s.battPct))|\(Int(s.fan))"
        if ms.contains(.cpu) { sig += "|" + h.map { String(Int($0)) }.joined(separator: ".") }
        guard sig != lastSignature else { return }
        lastSignature = sig

        bar.snap = s; bar.history = h; bar.metrics = ms
        let w = Bar.totalWidth(s, metrics: ms)
        if abs(statusItem.length - w) > 0.5 { statusItem.length = w }
        bar.needsDisplay = true
    }

    // MARK: interaction

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            if popover.contentViewController == nil {
                popover.contentViewController = NSHostingController(
                    rootView: DetailView(model: model, pCount: sensors.pCount, eCount: sensors.eCount))
            }
            model.snap = snap
            model.history = history

            // SwiftUI reports its height only after a layout pass. Without this the popover
            // is positioned before it knows its size and ends up running off the top of the
            // screen, behind the notch.
            if let view = popover.contentViewController?.view {
                view.layoutSubtreeIfNeeded()
                let fitted = view.fittingSize
                if fitted.height > 0 {
                    popover.contentSize = fitted
                    popover.contentViewController?.preferredContentSize = fitted
                }
            }

            queue.async { [weak self] in self?.sampleAll() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show in menu bar", action: nil, keyEquivalent: "").isEnabled = false

        for m in Metric.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(toggleMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = metrics.contains(m) ? .on : .off
            // Surfacing the cost keeps the "why is this lightweight" answer visible.
            item.toolTip = "Sampling cost: \(m.costNote)"
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let rate = NSMenuItem(title: "Refresh rate", action: nil, keyEquivalent: "")
        rate.isEnabled = false
        menu.addItem(rate)
        for v in [1.0, 2.0, 5.0] {
            let item = NSMenuItem(title: v == 1 ? "1 second" : "\(Int(v)) seconds",
                                  action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v
            item.state = AppDelegate.interval == v ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Vitals", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        }
    }

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = Metric(rawValue: raw) else { return }
        var next = metrics
        if let i = next.firstIndex(of: m) {
            guard next.count > 1 else { return }        // never leave the bar empty
            next.remove(at: i)
        } else {
            next.append(m)
        }
        // Keep a stable left-to-right order regardless of toggle sequence.
        next.sort { a, b in
            (Metric.allCases.firstIndex(of: a) ?? 0) < (Metric.allCases.firstIndex(of: b) ?? 0)
        }
        metrics = next
        Metric.enabled = next
        queue.async { [weak self] in self?.sampleAll() }
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        AppDelegate.interval = v
        timer?.cancel()
        timer = nil
        start()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("vitals: login item toggle failed — \(error.localizedDescription)")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)     // menu bar only: no Dock icon, no window
app.run()
