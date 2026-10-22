import SwiftUI
import AppKit

// MARK: - Model

struct Fan: Identifiable {
    let id: Int
    var actual: Double
    var min: Double
    var max: Double
    var target: Double
    var manual: Bool
}

enum SMC {
    static func number(_ key: String) -> Double? {
        var v = 0.0
        return smc_read_number(key, &v) ? v : nil
    }
}

@MainActor
final class FanModel: ObservableObject {
    @Published var fans: [Fan] = []
    @Published var cpuTemp: Double?
    @Published var helperInstalled = false
    @Published var lastError: String?
    /// RPM the user asked for per fan; nil = automatic.
    @Published var requested: [Int: Double] = [:]
    /// Slider positions per fan (kept here because @State needs Xcode's macro plugins).
    @Published var slider: [Int: Double] = [:]

    nonisolated static let helperPath = "/Library/Application Support/FanControl/fanctl"
    private var timer: Timer?
    private let tempKeys: [String]

    init() {
        // Discover which CPU temperature sensors this Mac exposes (Tp01…Tp0f on Apple Silicon, TC0P on Intel).
        let candidates = (0..<16).map { String(format: "Tp0%x", $0) } + ["TC0P", "TC0D", "TC0E"]
        tempKeys = candidates.filter { SMC.number($0).map { $0 > 0 && $0 < 130 } ?? false }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func refresh() {
        helperInstalled = Self.helperIsSetuidRoot()
        let count = Int(SMC.number("FNum") ?? 0)
        fans = (0..<count).map { i in
            Fan(id: i,
                actual: SMC.number("F\(i)Ac") ?? 0,
                min: SMC.number("F\(i)Mn") ?? 0,
                max: SMC.number("F\(i)Mx") ?? 0,
                target: SMC.number("F\(i)Tg") ?? 0,
                manual: (SMC.number("F\(i)Md") ?? 0) != 0)
        }
        let temps = tempKeys.compactMap { SMC.number($0) }
        cpuTemp = temps.isEmpty ? nil : temps.max()
    }

    private func tick() {
        refresh()
        // macOS can quietly take a fan back; re-assert any manual setting that got dropped.
        for fan in fans {
            if let rpm = requested[fan.id], !fan.manual || abs(fan.target - rpm) > 50 {
                run(["set", "\(fan.id)", "\(Int(rpm))"])
            }
        }
    }

    func setManual(_ fanID: Int, rpm: Double) {
        requested[fanID] = rpm
        slider[fanID] = rpm
        run(["set", "\(fanID)", "\(Int(rpm))"])
    }

    func setAuto(_ fanID: Int) {
        requested[fanID] = nil
        run(["auto", "\(fanID)"])
    }

    func setAll(rpm: Double?) {
        for fan in fans { requested[fan.id] = rpm; if let rpm { slider[fan.id] = rpm } }
        run(rpm.map { ["set", "all", "\(Int($0))"] } ?? ["auto", "all"])
    }

    func restoreAutomatic() {
        guard fans.contains(where: \.manual) || !requested.isEmpty, helperInstalled else { return }
        requested = [:]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.helperPath)
        p.arguments = ["auto", "all"]
        try? p.run()
        p.waitUntilExit()
    }

    private func run(_ args: [String]) {
        guard helperInstalled else {
            lastError = "Install the helper first."
            return
        }
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Self.helperPath)
            p.arguments = args
            let err = Pipe()
            p.standardError = err
            let message: String?
            do {
                try p.run()
                p.waitUntilExit()
                message = p.terminationStatus == 0 ? nil
                    : String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                message = error.localizedDescription
            }
            await MainActor.run {
                self.lastError = message
                self.refresh()
            }
        }
    }

    // MARK: Helper installation

    static func helperIsSetuidRoot() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: helperPath),
              let owner = attrs[.ownerAccountID] as? NSNumber,
              let perms = attrs[.posixPermissions] as? NSNumber else { return false }
        return owner.intValue == 0 && (perms.intValue & 0o4000) != 0
    }

    func installHelper() {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "fanctl")?.path else {
            lastError = "fanctl is missing from the app bundle."
            return
        }
        let dir = (Self.helperPath as NSString).deletingLastPathComponent
        let shell = [
            "install -d -o root -g wheel -m 0755 \(q(dir))",
            "test ! -L \(q(dir))",
            "test ! -L \(q(Self.helperPath))",
            "install -m 0755 \(q(bundled)) \(q(Self.helperPath + ".new"))",
            "mv -f \(q(Self.helperPath + ".new")) \(q(Self.helperPath))",
            "chown root:wheel \(q(Self.helperPath))",
            "chmod 4755 \(q(Self.helperPath))",
        ].joined(separator: " && ")
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        if let errorInfo, (errorInfo[NSAppleScript.errorNumber] as? Int) != -128 {
            lastError = errorInfo[NSAppleScript.errorMessage] as? String ?? "Install failed."
        } else {
            lastError = nil
        }
        refresh()
    }

    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: - Views

struct FanRow: View {
    let fan: Fan
    @ObservedObject var model: FanModel

    private var isManual: Bool { model.requested[fan.id] != nil }
    private var sliderValue: Binding<Double> {
        Binding(get: { model.slider[fan.id] ?? max(fan.target, fan.min) },
                set: { model.slider[fan.id] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "fan")
                Text(fan.id == 0 ? "Left fan" : fan.id == 1 ? "Right fan" : "Fan \(fan.id + 1)")
                    .font(.headline)
                Spacer()
                Text("\(Int(fan.actual)) rpm")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Picker("", selection: Binding(
                get: { isManual },
                set: { manual in
                    if manual { model.setManual(fan.id, rpm: sliderValue.wrappedValue) }
                    else { model.setAuto(fan.id) }
                })) {
                Text("Automatic").tag(false)
                Text("Manual").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if isManual {
                HStack {
                    Slider(value: sliderValue, in: fan.min...max(fan.max, fan.min + 1), step: 100) { editing in
                        if !editing { model.setManual(fan.id, rpm: sliderValue.wrappedValue) }
                    }
                    Text("\(Int(sliderValue.wrappedValue))")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: FanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fan Control").font(.title3.bold())
                Spacer()
                if let t = model.cpuTemp {
                    Label("\(Int(t.rounded()))°C", systemImage: "thermometer.medium")
                        .monospacedDigit()
                }
            }

            if model.fans.isEmpty {
                Text("No fans found on this Mac.").foregroundStyle(.secondary)
            }

            ForEach(model.fans) { fan in
                FanRow(fan: fan, model: model)
                Divider()
            }

            if !model.fans.isEmpty {
                HStack {
                    Button("All Auto") { model.setAll(rpm: nil) }
                    Button("Quiet") { model.setAll(rpm: model.fans[0].min) }
                    Button("50%") {
                        let f = model.fans[0]
                        model.setAll(rpm: ((f.min + (f.max - f.min) * 0.5) / 100).rounded() * 100)
                    }
                    Button("Max") { model.setAll(rpm: model.fans[0].max) }
                }
                .controlSize(.small)
            }

            if !model.helperInstalled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Changing fan speed needs a small privileged helper. You'll be asked for your password once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Install Helper…") { model.installHelper() }
                }
            }

            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Fans return to automatic when you quit.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: FanModel?
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.restoreAutomatic() }
    }
}

@main
struct FanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = FanModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
                .onAppear { delegate.model = model }
        } label: {
            Image(systemName: model.requested.isEmpty ? "fan" : "fan.fill")
            Text(model.fans.first.map { "\(Int($0.actual))" } ?? "")
        }
        .menuBarExtraStyle(.window)
    }
}
