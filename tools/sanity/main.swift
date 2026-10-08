// Range check over every sampler. Not a unit test suite: it confirms each sensor path
// still returns a plausible reading on real hardware, which is what actually breaks when
// Apple moves a key or changes a unit.
//
//   clang -O2 -c src/smc.c -o /tmp/smc.o -Isrc
//   swiftc -O -swift-version 5 -import-objc-header src/Bridging.h \
//       src/Sensors.swift tools/sanity/main.swift /tmp/smc.o \
//       -framework IOKit -framework AppKit -o /tmp/sanity && /tmp/sanity
//
// It lives in its own directory because Swift only allows top-level code in main.swift.
import Foundation

var failures = 0

func check(_ name: String, _ value: Double, _ lo: Double, _ hi: Double, _ unit: String = "") {
    let ok = value >= lo && value <= hi
    if !ok { failures += 1 }
    let label = name.padding(toLength: 16, withPad: " ", startingAt: 0)
    print("  \(ok ? "PASS" : "FAIL")  \(label) \(String(format: "%9.2f", value))\(unit)")
}

let s = Sensors()
print("cores: \(s.pCount)P + \(s.eCount)E")
check("pCount", Double(s.pCount), 1, 32)
check("eCount", Double(s.eCount), 1, 32)

_ = s.cpuLoad(); _ = s.network()          // both report deltas, so prime a baseline
Thread.sleep(forTimeInterval: 1.5)

print("\n-- cpu")
let cores = s.cpuLoad()
check("core count", Double(cores.count), Double(s.pCount + s.eCount), Double(s.pCount + s.eCount))
check("mean load", cores.isEmpty ? -1 : cores.reduce(0, +) / Double(cores.count), 0, 100, "%")
check("max core", cores.max() ?? -1, 0, 100, "%")

print("\n-- memory")
let m = s.memory()
check("used", m.pct, 1, 100, "%")
check("usedGB", m.usedGB, 0.1, m.totalGB)
check("totalGB", m.totalGB, 1, 1024, " GB")
check("swapGB", m.swapGB, 0, 256, " GB")
print("  INFO  pressure         \(m.pressure)")

print("\n-- thermal / power")
check("cpu temp", s.cpuTemp(), 10, 110, " C")
check("power", s.power(), 0.5, 200, " W")
check("fan", s.fanRPM(), 0, 10000, " rpm")
check("battery temp", s.batteryTemp(), 5, 80, " C")

print("\n-- disk / gpu")
let d = s.disk()
check("disk used", d.pct, 0, 100, "%")
check("disk free", d.freeGB, 0, d.totalGB)
check("gpu", s.gpuUsage(), 0, 100, "%")

print("\n-- battery")
let b = s.battery()
check("charge", b.pct, 0, 100, "%")
check("health", b.health, 50, 100, "%")
check("cycles", Double(b.cycles), 0, 5000)

print("\n-- network")
let n = s.network()
check("down", n.down, 0, 2e9, " B/s")
check("up", n.up, 0, 2e9, " B/s")

print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
exit(failures == 0 ? 0 : 1)
