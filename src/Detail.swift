import SwiftUI

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
    return String(cString: buf)
}

final class VitalsModel: ObservableObject {
    @Published var snap = Snapshot()
    @Published var history: [Double] = []
}

/// Thin horizontal meter used throughout the popover.
private struct Meter: View {
    let value: Double            // 0...1
    var tint: Color = .primary

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: max(geo.size.width * min(max(value, 0), 1), value > 0 ? 2 : 0))
            }
        }
        .frame(height: 4)
    }
}

private struct Row<Trailing: View>: View {
    let label: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing.monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

private func heatTint(_ c: Double) -> Color {
    switch c {
    case ..<65: return .green
    case ..<85: return .orange
    default:    return .red
    }
}

struct DetailView: View {
    @ObservedObject var model: VitalsModel
    let pCount: Int
    let eCount: Int

    private var s: Snapshot { model.snap }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            cpuSection
            Divider()
            thermalSection
            Divider()
            memorySection
            Divider()
            storageSection
            Divider()
            networkSection
            if s.battPct > 0 {
                Divider()
                batterySection
            }
        }
        .padding(14)
        .frame(width: 268)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(sysctlString("machdep.cpu.brand_string"))
                    .font(.system(size: 12, weight: .semibold))
                Text("\(pCount) performance · \(eCount) efficiency")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Row(label: "CPU") { Text("\(Int(s.cpu.rounded()))%").fontWeight(.medium) }
            Meter(value: s.cpu / 100)

            Row(label: "Performance") { Text("\(Int(s.pCore.rounded()))%") }
            Meter(value: s.pCore / 100, tint: .blue)

            Row(label: "Efficiency") { Text("\(Int(s.eCore.rounded()))%") }
            Meter(value: s.eCore / 100, tint: .teal)

            // Per-core columns: efficiency cores first, matching Mach's ordering.
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(s.perCore.enumerated()), id: \.offset) { i, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < eCount ? Color.teal : Color.blue)
                        .opacity(0.25 + 0.75 * (v / 100))
                        .frame(height: 3 + 15 * (v / 100))
                }
            }
            .frame(height: 18)
            .padding(.top, 2)
        }
    }

    private var thermalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Row(label: "CPU temperature") {
                Text(s.temp > 0 ? "\(Int(s.temp.rounded()))°C" : "—")
                    .foregroundStyle(heatTint(s.temp))
                    .fontWeight(.medium)
            }
            Row(label: "Power draw") { Text(String(format: "%.1f W", s.watts)) }
            Row(label: "Fan") { Text(s.fan > 0 ? "\(Int(s.fan)) rpm" : "off") }
            if s.gpu > 0 { Row(label: "GPU") { Text("\(Int(s.gpu.rounded()))%") } }
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Row(label: "Memory") {
                Text(String(format: "%.1f / %.0f GB", s.ramUsedGB, s.ramTotalGB)).fontWeight(.medium)
            }
            Meter(value: s.ramPct / 100, tint: s.ramPct > 85 ? .orange : .primary)
            Row(label: "Pressure") { Text(s.pressure) }
            Row(label: "Swap") { Text(String(format: "%.2f GB", s.swapGB)) }
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Row(label: "Disk") {
                Text(String(format: "%.0f GB free", s.diskFreeGB)).fontWeight(.medium)
            }
            Meter(value: s.diskPct / 100)
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Row(label: "Network down") { Text(rateText(s.netDown)).fontWeight(.medium) }
            Row(label: "Network up") { Text(rateText(s.netUp)) }
        }
    }

    private func rateText(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1 { return "0 KB/s" }
        if kb < 1024 { return String(format: "%.0f KB/s", kb) }
        return String(format: "%.2f MB/s", kb / 1024)
    }

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Row(label: s.charging ? "Battery (charging)" : "Battery") {
                Text("\(Int(s.battPct.rounded()))%").fontWeight(.medium)
            }
            Meter(value: s.battPct / 100, tint: s.battPct < 20 && !s.charging ? .red : .green)
            Row(label: "Health") { Text(s.battHealth > 0 ? "\(Int(s.battHealth.rounded()))%" : "—") }
            Row(label: "Cycles") { Text("\(s.battCycles)") }
            if s.timeLeft > 0 {
                Row(label: s.charging ? "Until full" : "Remaining") {
                    Text("\(s.timeLeft / 60)h \(s.timeLeft % 60)m")
                }
            }
            if s.battTemp > 0 {
                Row(label: "Battery temp") { Text("\(Int(s.battTemp.rounded()))°C") }
            }
        }
    }
}
