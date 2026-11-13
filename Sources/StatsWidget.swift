import AppKit
import SwiftUI
import IOKit
import Darwin

// MARK: - Tasarım paleti

private extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

private enum Palette {
    static let cardTop = Color(hex: 0x1A1E27)
    static let cardBottom = Color(hex: 0x090B10)
    static let label = Color.white.opacity(0.42)
    static let text = Color.white.opacity(0.95)
    static let subtext = Color.white.opacity(0.55)
    static let track = Color.white.opacity(0.08)
    static let cpu = Color(hex: 0x4FE3BD)
    static let temp = Color(hex: 0xFFB26B)
    static let ram = Color(hex: 0x6AA9FF)
    static let gpu = Color(hex: 0xB98CFF)
    static let eCore = Color(hex: 0x9FE8CB)
    static let warning = Color(hex: 0xFFB26B)
}

private let cardWidth: CGFloat = 300
private let cardPadding: CGFloat = 18
private let outerPadding: CGFloat = 18
private let bundleID = "com.erdinc.statswidget"

// MARK: - Veri modeli

struct Snapshot {
    var cpuUsage: Double = 0
    var cpuCores: [Double] = []
    var ramUsed: UInt64 = 0
    var ramTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var gpuUsage: Double?
    var pFreqMHz: Double?
    var eFreqMHz: Double?
    var pActive: [Double] = []
    var eActive: [Double] = []
    var cpuTemp: Double?
    var macmonFresh = false

    var ramFraction: Double {
        ramTotal == 0 ? 0 : min(1, max(0, Double(ramUsed) / Double(ramTotal)))
    }
}

struct MacmonSample: Decodable {
    struct Core: Decodable {
        let activeRatio: Double?
    }

    struct Memory: Decodable {
        let ramUsage: UInt64?
        let ramTotal: UInt64?
    }

    struct Temperature: Decodable {
        let cpuTempAvg: Double?
    }

    let ecpuFreqMhz: Double?
    let pcpuFreqMhz: Double?
    let gpuActiveRatio: Double?
    let ecpuCores: [Core]?
    let pcpuCores: [Core]?
    let memory: Memory?
    let temp: Temperature?
}

// MARK: - macmon okuyucu (P/E frekansları ve sıcaklık)

final class MacmonRunner {
    private let queue = DispatchQueue(label: "com.erdinc.statswidget.macmon")
    private var process: Process?
    private var buffer = ""
    private var stopped = false
    private var restartWorkItem: DispatchWorkItem?

    /// Ana thread'e gönderilir.
    var onSample: ((MacmonSample) -> Void)?

    static func locateBinary() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("macmon"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/macmon"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/macmon"))
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("macmon"))
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func start() {
        queue.async { self.startLocked() }
    }

    func stop() {
        queue.sync {
            stopped = true
            restartWorkItem?.cancel()
            process?.terminate()
            process = nil
        }
    }

    private func startLocked() {
        guard !stopped, process == nil else { return }
        guard let binary = Self.locateBinary() else {
            scheduleRestart(after: 5)
            return
        }

        let task = Process()
        task.executableURL = binary
        task.arguments = ["pipe", "-i", "1000"]
        task.qualityOfService = .utility

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async {
                guard !self.stopped else { return }
                self.consume(data)
            }
        }

        task.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.process = nil
                self.buffer.removeAll()
                pipe.fileHandleForReading.readabilityHandler = nil
                if !self.stopped {
                    self.scheduleRestart(after: 3)
                }
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            scheduleRestart(after: 5)
        }
    }

    private func scheduleRestart(after seconds: TimeInterval) {
        guard !stopped else { return }
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.startLocked()
        }
        restartWorkItem = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func consume(_ data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            guard let lineData = line.data(using: .utf8), !line.isEmpty else { continue }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let sample = try? decoder.decode(MacmonSample.self, from: lineData) else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.onSample?(sample)
            }
        }
        if buffer.count > 1_000_000 {
            buffer.removeAll()
        }
    }
}

// MARK: - Yerel ölçümler (CPU / RAM / GPU)

struct CPUSampler {
    private struct Ticks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private var previous: [Ticks] = []

    mutating func sample() -> (usage: Double, cores: [Double]) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )

        guard result == KERN_SUCCESS, let info else {
            return (0, [])
        }

        defer {
            let bytes = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), bytes)
        }

        let states = Int(CPU_STATE_MAX)
        var current: [Ticks] = []
        current.reserveCapacity(Int(cpuCount))

        for index in 0..<Int(cpuCount) {
            let base = index * states
            current.append(
                Ticks(
                    user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                    system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                    idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                    nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
                )
            )
        }

        guard previous.count == current.count else {
            previous = current
            return (0, current.map { _ in 0 })
        }

        var usedTotal: Double = 0
        var allTotal: Double = 0
        var cores: [Double] = []
        cores.reserveCapacity(current.count)

        for (old, new) in zip(previous, current) {
            let user = Double(new.user &- old.user)
            let system = Double(new.system &- old.system)
            let idle = Double(new.idle &- old.idle)
            let nice = Double(new.nice &- old.nice)
            let all = user + system + idle + nice
            let used = user + system + nice
            allTotal += all
            usedTotal += used
            cores.append(all > 0 ? min(1, max(0, used / all)) : 0)
        }

        previous = current
        let usage = allTotal > 0 ? min(1, max(0, usedTotal / allTotal)) : 0
        return (usage, cores)
    }
}

enum MemoryReader {
    static func read() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return (0, total)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let appPages = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count))
        let usedPages = appPages + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        let used = min(total, UInt64(max(0, usedPages)) * pageSize)
        return (used, total)
    }
}

enum GPUReader {
    static func read() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let performance = dictionary["PerformanceStatistics"] as? [String: Any],
                  let utilization = performance["Device Utilization %"] as? NSNumber
            else { continue }

            let value = utilization.doubleValue
            best = max(best ?? 0, value)
        }

        guard let best else { return nil }
        return min(1, max(0, best / 100))
    }
}

// MARK: - Model

@MainActor
final class StatsModel: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var chipName = StatsModel.machineName()
    @Published private(set) var hasMacmon = MacmonRunner.locateBinary() != nil
    @Published private(set) var pCoreCount = 4
    @Published private(set) var eCoreCount = 4

    private var cpuSampler = CPUSampler()
    private var timer: Timer?
    private let macmon = MacmonRunner()
    private var lastMacmon: MacmonSample?
    private var lastMacmonAt: Date?

    init() {
        pCoreCount = Self.coreCount(perfLevel: 0, fallback: 4)
        eCoreCount = Self.coreCount(perfLevel: 1, fallback: 4)

        macmon.onSample = { [weak self] sample in
            Task { @MainActor in
                guard let self else { return }
                self.lastMacmon = sample
                self.lastMacmonAt = Date()
                self.hasMacmon = true
            }
        }
    }

    func start() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        timer.tolerance = 0.12
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        macmon.start()
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        macmon.stop()
    }

    func refresh() {
        tick()
    }

    private func tick() {
        let cpu = cpuSampler.sample()
        let memory = MemoryReader.read()

        var next = snapshot
        next.cpuUsage = cpu.usage
        next.cpuCores = cpu.cores
        next.ramUsed = memory.used
        next.ramTotal = memory.total
        next.gpuUsage = GPUReader.read()

        let fresh = lastMacmonAt.map { Date().timeIntervalSince($0) < 4 } ?? false
        if fresh, let sample = lastMacmon {
            next.macmonFresh = true
            next.pFreqMHz = sample.pcpuFreqMhz
            next.eFreqMHz = sample.ecpuFreqMhz
            next.pActive = sample.pcpuCores?.compactMap(\.activeRatio) ?? []
            next.eActive = sample.ecpuCores?.compactMap(\.activeRatio) ?? []
            next.cpuTemp = sample.temp?.cpuTempAvg
            if next.gpuUsage == nil {
                next.gpuUsage = sample.gpuActiveRatio
            }
        } else {
            next.macmonFresh = false
            next.pFreqMHz = nil
            next.eFreqMHz = nil
            next.pActive = []
            next.eActive = []
            next.cpuTemp = nil
            next.gpuUsage = next.gpuUsage ?? lastMacmon?.gpuActiveRatio
        }

        next.ramTotal = next.ramTotal == 0 ? ProcessInfo.processInfo.physicalMemory : next.ramTotal
        snapshot = next
    }

    private static func coreCount(perfLevel: Int, fallback: Int) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        let name = "hw.perflevel\(perfLevel).logicalcpu"
        if sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return fallback
    }

    private static func machineName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "Mac"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return "Mac"
        }
        let name = String(cString: buffer)
        return name.isEmpty ? "Mac" : name
    }
}

// MARK: - Yardımcı görünümler

private struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.15)
            .foregroundStyle(Palette.label)
    }
}

private struct MeterBar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.55), color],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: value <= 0.005 ? 0 : max(height, geometry.size.width * min(1, value)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

private struct ClusterRow: View {
    let badge: String
    let title: String
    let freqMHz: Double?
    let active: [Double]
    let expectedCores: Int
    let color: Color

    private var dotCount: Int {
        max(active.count, expectedCores)
    }

    private var freqText: String {
        guard let freqMHz, freqMHz > 0 else { return "—" }
        return String(format: "%.2f", freqMHz / 1000)
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(badge)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 15, height: 15)
                .background(Circle().fill(color.opacity(0.16)))

            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.65)
                .foregroundStyle(Palette.label)

            HStack(spacing: 3) {
                ForEach(0..<dotCount, id: \.self) { index in
                    let ratio = index < active.count ? active[index] : 0
                    Circle()
                        .fill(color.opacity(0.16 + 0.84 * min(1, max(0, ratio))))
                        .frame(width: 4.5, height: 4.5)
                }
            }
            .padding(.leading, 1)

            Spacer(minLength: 2)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(freqText)
                    .font(.system(size: 16.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(freqMHz == nil ? Palette.subtext : Palette.text)
                Text("GHz")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.label)
            }
        }
        .frame(height: 22)
    }
}

// MARK: - Widget arayüzü

struct WidgetView: View {
    @ObservedObject var model: StatsModel

    var onToggleLogin: () -> Void

    private var cpuPercent: Int { Int((model.snapshot.cpuUsage * 100).rounded()) }
    private var ramPercent: Int { Int((model.snapshot.ramFraction * 100).rounded()) }
    private var gpuPercent: Int? {
        model.snapshot.gpuUsage.map { Int((min(1, max(0, $0)) * 100).rounded()) }
    }

    private var tempText: String {
        guard let temp = model.snapshot.cpuTemp else { return "—" }
        return "\(Int(temp.rounded()))"
    }

    private var ramDetail: String {
        let usedGB = Double(model.snapshot.ramUsed) / 1_073_741_824
        let totalGB = Double(model.snapshot.ramTotal) / 1_073_741_824
        return String(format: "%.1f / %.0f GB", usedGB, totalGB)
    }

    private var loginEnabled: Bool { LoginItem.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 14)

            hero
                .padding(.bottom, 14)

            clusterBox
                .padding(.bottom, 14)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
                .padding(.bottom, 13)

            memorySection
                .padding(.bottom, 12)

            gpuSection
        }
        .padding(cardPadding)
        .frame(width: cardWidth, alignment: .leading)
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(color: Color.black.opacity(0.5), radius: 16, x: 0, y: 10)
        .padding(outerPadding)
        .contextMenu { contextMenu }
    }

    // MARK: Bölümler

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.snapshot.macmonFresh ? Palette.cpu : Palette.warning)
                .frame(width: 5, height: 5)
                .shadow(color: (model.snapshot.macmonFresh ? Palette.cpu : Palette.warning).opacity(0.8), radius: 4)

            Text("SYSTEM")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.35)
                .foregroundStyle(Color.white.opacity(0.58))

            Spacer(minLength: 6)

            if !model.hasMacmon {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.warning)
                    .help("macmon bulunamadı: frekans ve sıcaklık okunamıyor.")
            }

            Text(model.chipName)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.36))
        }
        .frame(height: 12)
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                SectionLabel("CPU USAGE")
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(cpuPercent)")
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.text)
                        .contentTransition(.numericText(value: Double(cpuPercent)))
                    Text("%")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.subtext)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                SectionLabel("CPU TEMP")
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 11, weight: .semibold))
                    Text(tempText)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if model.snapshot.cpuTemp != nil {
                        Text("°C")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                }
                .foregroundStyle(model.snapshot.cpuTemp == nil ? Palette.subtext : Palette.temp)
                .contentTransition(.numericText())
            }
            .help("Apple Silicon'da CPU sıcaklığı (PMU sensörlerinin ortalaması)")
        }
        .animation(.easeOut(duration: 0.3), value: cpuPercent)
    }

    private var clusterBox: some View {
        VStack(spacing: 8) {
            ClusterRow(
                badge: "P",
                title: "PERFORMANCE",
                freqMHz: model.snapshot.pFreqMHz,
                active: model.snapshot.pActive,
                expectedCores: model.pCoreCount,
                color: Palette.cpu
            )
            ClusterRow(
                badge: "E",
                title: "EFFICIENCY",
                freqMHz: model.snapshot.eFreqMHz,
                active: model.snapshot.eActive,
                expectedCores: model.eCoreCount,
                color: Palette.eCore
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("MEMORY")
                Spacer()
                Text(ramDetail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.subtext)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(ramPercent)")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ram)
                    .contentTransition(.numericText(value: Double(ramPercent)))
                Text("%")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.ram.opacity(0.65))
                Spacer()
            }

            MeterBar(value: model.snapshot.ramFraction, color: Palette.ram)
        }
        .animation(.easeOut(duration: 0.3), value: ramPercent)
    }

    private var gpuSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("GPU")
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(gpuPercent.map(String.init) ?? "—")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(gpuPercent == nil ? Palette.subtext : Palette.gpu)
                    .contentTransition(.numericText())
                if gpuPercent != nil {
                    Text("%")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.gpu.opacity(0.65))
                }
                Spacer()
            }

            MeterBar(value: model.snapshot.gpuUsage ?? 0, color: Palette.gpu)
        }
        .animation(.easeOut(duration: 0.3), value: gpuPercent)
    }

    // MARK: Arka plan

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Palette.cardTop, Palette.cardBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [Palette.cpu.opacity(0.075), .clear],
                            center: .topLeading,
                            startRadius: 8,
                            endRadius: 230
                        )
                    )
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.17), Color.white.opacity(0.035)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
    }

    // MARK: Sağ tık menüsü

    @ViewBuilder
    private var contextMenu: some View {
        Button(loginEnabled ? "Girişte Açmayı Kapat" : "Girişte Aç") { onToggleLogin() }
        Divider()
        Button("Çıkış") { NSApplication.shared.terminate(nil) }
    }
}

// MARK: - Pencere / uygulama

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override var isOpaque: Bool { false }
}

enum LoginItem {
    static let label = bundleID + ".login"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        let manager = FileManager.default
        if enabled {
            try manager.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let executable = Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/StatsWidget")
                .path
            let contents: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "StandardOutPath": "/tmp/statswidget.log",
                "StandardErrorPath": "/tmp/statswidget.log"
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: contents,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL, options: .atomic)
        } else {
            try? manager.removeItem(at: plistURL)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: WidgetWindow!
    private var model: StatsModel!

    private let originXKey = "widgetOriginX"
    private let originYKey = "widgetOriginY"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }

        model = StatsModel()
        setupWindow()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    // MARK: Pencere

    private func setupWindow() {
        let root = WidgetView(
            model: model,
            onToggleLogin: { [weak self] in self?.toggleLogin() }
        )

        let hosting = DraggableHostingView(rootView: root)
        hosting.layer?.backgroundColor = .clear

        var size = NSSize(width: cardWidth + outerPadding * 2, height: 0)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: 420))
        hosting.layoutSubtreeIfNeeded()
        let fitted = hosting.fittingSize
        size.height = (fitted.height > 120 && fitted.height < 900) ? fitted.height : 382

        let origin = savedOrigin(for: size)
        let frame = NSRect(origin: origin, size: size)

        let window = WidgetWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.orderFrontRegardless()

        self.window = window

        // SwiftUI içerik görünümleri fare olaylarını yuttuğu için sürüklemeyi
        // pencere seviyesinde yakalıyoruz: sol tık basılı tutulunca pencere taşınır.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else {
                return event
            }
            window.performDrag(with: event)
            return nil
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return NSPoint(x: 40, y: 40) }
        return NSPoint(
            x: visible.maxX - size.width - 8,
            y: visible.maxY - size.height - 8
        )
    }

    private func savedOrigin(for size: NSSize) -> NSPoint {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: originXKey) != nil else {
            return defaultOrigin(for: size)
        }
        let point = NSPoint(
            x: defaults.double(forKey: originXKey),
            y: defaults.double(forKey: originYKey)
        )
        let rect = NSRect(origin: point, size: size)
        let isVisible = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersection(rect).width > 80
                && screen.visibleFrame.intersection(rect).height > 80
        }
        return isVisible ? point : defaultOrigin(for: size)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        let origin = window.frame.origin
        UserDefaults.standard.set(origin.x, forKey: originXKey)
        UserDefaults.standard.set(origin.y, forKey: originYKey)
    }

    @objc private func screensChanged() {
        guard let window else { return }
        let size = window.frame.size
        let rect = window.frame
        let visible = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersection(rect).width > 80
                && screen.visibleFrame.intersection(rect).height > 80
        }
        if !visible {
            window.setFrameOrigin(defaultOrigin(for: size))
        }
    }

    private func toggleLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Giriş öğesi değiştirilemedi"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

// MARK: - Giriş noktası

@main
struct StatsWidgetMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
