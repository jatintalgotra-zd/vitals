import Foundation
import IOKit
import IOKit.ps

struct Snapshot {
    var cpu = 0.0                 // whole-machine busy %
    var pCore = 0.0               // performance cluster busy %
    var eCore = 0.0               // efficiency cluster busy %
    var perCore: [Double] = []

    var ramPct = 0.0, ramUsedGB = 0.0, ramTotalGB = 0.0
    var swapGB = 0.0, pressure = "—"

    var diskPct = 0.0, diskFreeGB = 0.0, diskTotalGB = 0.0

    var temp = 0.0                // CPU die °C
    var battTemp = 0.0
    var watts = 0.0               // whole-system draw
    var fan = 0.0                 // RPM
    var gpu = 0.0                 // %

    var battPct = 0.0, battHealth = 0.0, battCycles = 0
    var charging = false, timeLeft = -1

    var netDown = 0.0, netUp = 0.0     // bytes per second
}

func sysctlInt(_ name: String) -> Int {
    var v = 0
    var sz = MemoryLayout<Int>.size
    return sysctlbyname(name, &v, &sz, nil, 0) == 0 ? v : 0
}

final class Sensors {
    /// Verified empirically on M4: Mach lists efficiency cores first, performance cores last.
    let eCount = sysctlInt("hw.perflevel1.logicalcpu")
    let pCount = sysctlInt("hw.perflevel0.logicalcpu")
    private let totalRAM = Double(ProcessInfo.processInfo.physicalMemory)

    private var prevBusy: [Double] = []
    private var prevTotal: [Double] = []
    private var prevRx: UInt64 = 0, prevTx: UInt64 = 0, prevNetAt: CFAbsoluteTime = 0

    init() { _ = smc_open() }
    deinit { smc_close() }

    // MARK: fast tier — microseconds, safe at 1Hz

    /// Returns per-core busy %, or an empty array on the very first call (no baseline yet).
    func cpuLoad() -> [Double] {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var cnt: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS,
              let arr = info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: arr), vm_size_t(cnt) * 4) }

        var busy = [Double](repeating: 0, count: Int(n))
        var total = [Double](repeating: 0, count: Int(n))
        arr.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { p in
            for c in 0..<Int(n) {
                let o = c * Int(CPU_STATE_MAX)
                let u = Double(p[o + Int(CPU_STATE_USER)])
                let s = Double(p[o + Int(CPU_STATE_SYSTEM)])
                let ni = Double(p[o + Int(CPU_STATE_NICE)])
                let id = Double(p[o + Int(CPU_STATE_IDLE)])
                busy[c] = u + s + ni
                total[c] = u + s + ni + id
            }
        }
        defer { prevBusy = busy; prevTotal = total }
        guard prevBusy.count == busy.count else { return [] }

        return (0..<busy.count).map { i in
            let dt = total[i] - prevTotal[i]
            return dt > 0 ? min(100, max(0, (busy[i] - prevBusy[i]) / dt * 100)) : 0
        }
    }

    /// Throughput in bytes per second since the previous call.
    ///
    /// Counts en* interfaces only. Those carry the real traffic, so tunnels (utun*, ipsec*)
    /// would report the same bytes a second time and roughly double the figure for anyone
    /// on a VPN. Loopback is excluded for the same reason.
    func network() -> (down: Double, up: Double) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifap) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        var cursor = ifap
        while let cur = cursor {
            defer { cursor = cur.pointee.ifa_next }
            guard cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: cur.pointee.ifa_name).hasPrefix("en"),
                  let d = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            rx += UInt64(d.pointee.ifi_ibytes)
            tx += UInt64(d.pointee.ifi_obytes)
        }

        let now = CFAbsoluteTimeGetCurrent()
        defer { prevRx = rx; prevTx = tx; prevNetAt = now }

        // No baseline yet, or counters went backwards because an interface reset.
        guard prevNetAt > 0, now > prevNetAt, rx >= prevRx, tx >= prevTx else { return (0, 0) }
        let dt = now - prevNetAt
        return (Double(rx - prevRx) / dt, Double(tx - prevTx) / dt)
    }

    func memory() -> (pct: Double, usedGB: Double, totalGB: Double, swapGB: Double, pressure: String) {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var v = vm_statistics64_data_t()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &v) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0, totalRAM / 1e9, 0, "—") }

        // "Used" as macOS counts it: resident + wired + compressed. Inactive is reclaimable.
        let used = Double(UInt64(v.active_count) + UInt64(v.wire_count) + UInt64(v.compressor_page_count))
                 * Double(pageSize)

        var xsw = xsw_usage()
        var xswSize = MemoryLayout<xsw_usage>.size
        let swap = sysctlbyname("vm.swapusage", &xsw, &xswSize, nil, 0) == 0 ? Double(xsw.xsu_used) : 0

        let level = sysctlInt("kern.memorystatus_vm_pressure_level")
        let label = level == 1 ? "Normal" : level == 2 ? "Warning" : level == 4 ? "Critical" : "—"

        return (used / totalRAM * 100, used / 1_073_741_824, totalRAM / 1_073_741_824,
                swap / 1_073_741_824, label)
    }

    // MARK: medium tier — ~700us for both keys, run at 3s

    /// P-core die temperature. Tp01/Tp09 match what Sensei and iStat report.
    func cpuTemp() -> Double {
        var acc = 0.0, n = 0
        for key in ["Tp01", "Tp09"] {
            var v = 0.0
            if smc_read(key, &v), v > 0, v < 120 { acc += v; n += 1 }
        }
        return n > 0 ? acc / Double(n) : 0
    }

    func power() -> Double { read("PSTR", max: 200) }
    func fanRPM() -> Double { read("F0Ac", max: 10000) }
    func batteryTemp() -> Double { read("TB0T", max: 120) }

    private func read(_ key: String, max limit: Double) -> Double {
        var v = 0.0
        guard smc_read(key, &v), v >= 0, v < limit else { return 0 }
        return v
    }

    // MARK: slow tier — run at 30s

    func disk() -> (pct: Double, freeGB: Double, totalGB: Double) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let vals = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = vals.volumeTotalCapacity,
              let free = vals.volumeAvailableCapacityForImportantUsage else { return (0, 0, 0) }
        let t = Double(total), f = Double(free)
        return ((t - f) / t * 100, f / 1_073_741_824, t / 1_073_741_824)
    }

    func gpuUsage() -> Double {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iter) }

        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any],
                  let util = stats["Device Utilization %"] as? Int else { continue }
            return Double(util)
        }
        return 0
    }

    func battery() -> (pct: Double, health: Double, cycles: Int, charging: Bool, timeLeft: Int) {
        var pct = 0.0, charging = false, timeLeft = -1
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any]
                else { continue }
                if let cur = d[kIOPSCurrentCapacityKey] as? Int, let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0 {
                    pct = Double(cur) / Double(mx) * 100
                }
                charging = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0 { timeLeft = t }
                if charging, let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0 { timeLeft = t }
            }
        }

        var health = 0.0, cycles = 0
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any] {
                cycles = d["CycleCount"] as? Int ?? 0

                // Several capacity keys exist and they disagree. AppleRawMaxCapacity is an
                // instantaneous estimate that reads low while charging; the nominal figures are
                // filtered. ShutDownNominalChargeCapacity is the one that reproduces the
                // "Maximum Capacity" percentage System Settings reports on this hardware.
                // Deliberately NOT MaxCapacity — on Apple Silicon that is a percentage (100),
                // not a charge in mAh, so using it as a fallback yields nonsense.
                // ShutDownNominalChargeCapacity is nested, not top level. It is also the only
                // one of these that holds steady as the charge level moves, which is what a
                // health figure should do.
                let shutdown = d["BatteryShutdownReason"] as? [String: Any] ?? [:]
                let candidates = [shutdown["ShutDownNominalChargeCapacity"],
                                  d["NominalChargeCapacity"],
                                  d["AppleRawMaxCapacity"]]
                if let design = d["DesignCapacity"] as? Int, design > 0,
                   let maxCap = candidates.lazy.compactMap({ $0 as? Int }).first(where: { $0 > 0 }) {
                    health = Double(maxCap) / Double(design) * 100
                }
            }
        }
        return (pct, health, cycles, charging, timeLeft)
    }
}
