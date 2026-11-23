import Foundation
import IOKit
import IOKit.ps
import Observation

enum ThermalLevel: Sendable {
    case nominal, fair, serious, critical

    var title: String {
        switch self {
        case .nominal: "Норма"
        case .fair: "Тепло"
        case .serious: "Горячо"
        case .critical: "Перегрев"
        }
    }
}

struct SystemSnapshot: Equatable, Sendable {
    /// Загрузка процессора, 0...1.
    var cpu: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var batteryPercent: Int?
    var onPower = false
    var isCharging = false
    var minutesRemaining: Int?
    /// Температура аккумулятора в градусах. Температуру процессора macOS без привилегий не отдаёт.
    var batteryTemperature: Double?
    var thermal: ThermalLevel = .nominal
}

struct BluetoothBattery: Equatable, Sendable {
    let label: String
    let percent: Int
}

struct BluetoothDevice: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let connected: Bool
    let batteries: [BluetoothBattery]
}

struct HotProcess: Identifiable, Equatable, Sendable {
    var id: Int { pid }
    let pid: Int
    let name: String
    /// Процент одного ядра, поэтому может быть больше 100.
    let cpu: Double
}

/// Запуск системной утилиты с чтением всего вывода. Работает вне главного потока.
enum Shell {
    static func run(_ path: String, _ arguments: [String]) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

/// Данные вкладки Dev: загрузка, память, батарея, Bluetooth и процессы, которые греют Mac.
/// Всё опрашивается только пока вкладка открыта (опросы идут из `.task` страницы).
@MainActor @Observable
final class SystemMonitor {
    static let shared = SystemMonitor()

    var snapshot = SystemSnapshot()
    var bluetooth: [BluetoothDevice] = []
    var hot: [HotProcess] = []

    @ObservationIgnored private var lastTicks: (used: UInt64, total: UInt64)?

    // MARK: Опросы

    func sample() {
        var next = snapshot
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                next.cpu = min(1, Double(ticks.used - last.used) / Double(ticks.total - last.total))
            }
            lastTicks = ticks
        }
        next.memoryUsed = Self.memoryUsed()
        let battery = Self.battery()
        next.batteryPercent = battery?.percent
        next.onPower = battery?.onPower ?? false
        next.isCharging = battery?.charging ?? false
        next.minutesRemaining = battery?.minutes
        next.batteryTemperature = Self.batteryTemperature()
        next.thermal = Self.thermalLevel()
        snapshot = next
    }

    func refreshBluetooth() async {
        guard let text = await Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]) else { return }
        bluetooth = Self.parseBluetooth(Data(text.utf8))
    }

    func refreshHot() async {
        guard let text = await Shell.run("/usr/bin/top", ["-l", "2", "-n", "8", "-o", "cpu", "-stats", "pid,command,cpu", "-s", "1"]) else { return }
        hot = Self.parseTop(text)
    }

    // MARK: Системные счётчики

    private static func cpuTicks() -> (used: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let used = user + system + nice
        return (used, used + idle)
    }

    /// Так же, как «Память» в мониторинге системы: программы, закреплённая и сжатая память.
    private static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(sysconf(_SC_PAGESIZE))
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    static func battery() -> (percent: Int, onPower: Bool, charging: Bool, minutes: Int?)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let percent = description[kIOPSCurrentCapacityKey] as? Int else { continue }
            let onPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (description[key] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return (percent, onPower, charging, minutes)
        }
        return nil
    }

    private static func batteryTemperature() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int else { return nil }
        return Double(raw) / 100
    }

    private static func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    // MARK: Разбор вывода утилит

    /// `system_profiler SPBluetoothDataType -json`: подключённые устройства и заряд, который macOS запомнил у остальных.
    nonisolated static func parseBluetooth(_ data: Data) -> [BluetoothDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let section = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return [] }
        let levels: [(key: String, label: String)] = [
            ("device_batteryLevelMain", "Заряд"), ("device_batteryLevelLeft", "Левый"),
            ("device_batteryLevelRight", "Правый"), ("device_batteryLevelCase", "Кейс"),
        ]
        func read(_ key: String, connected: Bool) -> [BluetoothDevice] {
            (section[key] as? [[String: Any]] ?? []).compactMap { entry in
                guard let name = entry.keys.first, let props = entry[name] as? [String: Any] else { return nil }
                let batteries = levels.compactMap { level -> BluetoothBattery? in
                    guard let text = props[level.key] as? String, let percent = Int(text.filter(\.isNumber)) else { return nil }
                    return BluetoothBattery(label: level.label, percent: percent)
                }
                // Отключённые без заряда неинтересны: их десятки (старые наушники, колонки).
                guard connected || !batteries.isEmpty else { return nil }
                return BluetoothDevice(name: name, connected: connected, batteries: batteries)
            }
        }
        return read("device_connected", connected: true) + read("device_not_connected", connected: false)
    }

    /// `top -l 2 ...`: берётся второй замер, первый показывает среднее с запуска системы.
    nonisolated static func parseTop(_ text: String) -> [HotProcess] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [] }
        return lines[(header + 1)...].compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]), let cpu = Double(parts[parts.count - 1].replacingOccurrences(of: ",", with: ".")) else { return nil }
            let name = parts[1..<(parts.count - 1)].joined(separator: " ")
            guard name != "top", cpu > 0 else { return nil }
            return HotProcess(pid: pid, name: name, cpu: cpu)
        }
    }
}
