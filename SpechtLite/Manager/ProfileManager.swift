import Cocoa
import ReactiveSwift
import CocoaLumberjackSwift
import Darwin

class ProfileManager {
    static let profiles: MutableProperty<[String: String]> = MutableProperty([:])
    static let profileNames: Property<[String]> = Property(profiles.map { $0.keys.sorted() })
    static let currentProfile: MutableProperty<String?> = MutableProperty(nil)
    static let currentProxyPort: MutableProperty<UInt16?> = MutableProperty(nil)
    static let allowFromLan: MutableProperty<Bool> = MutableProperty(false)

    private static let coreRunner = TcpRouteRunner {
        DispatchQueue.main.async {
            currentProxyPort.swap(nil)
            DDLogError("[TcpRoute] process exited unexpectedly")
        }
    }

    static var profileFolder: String {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(Opt.configurationFolder)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if exists && !isDirectory.boolValue {
            try? FileManager.default.removeItem(atPath: path)
        }
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }
        return path
    }

    static func setUp() {
        guard validateInstallation() else {
            profiles.swap([:])
            return
        }
        reloadAllProfileFiles()

        profiles.producer.startWithValues { _ in
            currentProfile.modify { $0 }
        }
        currentProfile.producer.startWithValues { name in
            runProfile(name: name)
        }
        allowFromLan.producer.startWithValues { _ in
            runProfile(name: currentProfile.value)
        }
    }

    static func openProfileFolder() {
        NSWorkspace.shared.openFile(profileFolder)
    }

    static func reloadAllProfileFiles() {
        var loadedProfiles: [String: String] = [:]
        do {
            let paths = try FileManager.default.contentsOfDirectory(atPath: profileFolder)
                .filter { ($0 as NSString).pathExtension.lowercased() == "toml" }
                .sorted()
            for path in paths {
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                let fullPath = (profileFolder as NSString).appendingPathComponent(path)
                do {
                    let content = try String(contentsOfFile: fullPath, encoding: .utf8)
                    _ = try TcpRouteProfile.prepare(content: content, allowFromLan: false)
                    loadedProfiles[name] = content
                } catch let error {
                    Utils.alertError("Error when loading TcpRoute profile \(fullPath). \(error)")
                }
            }
        } catch let error {
            Utils.alertError("Error when loading TcpRoute profile folder: \(profileFolder). \(error)")
        }
        profiles.swap(loadedProfiles)
    }

    @discardableResult
    private static func runProfile(name: String?) -> Bool {
        stopProxyServer()
        guard let name = name else {
            currentProxyPort.swap(nil)
            return true
        }
        guard let profile = profiles.value[name] else {
            currentProxyPort.swap(nil)
            return false
        }
        do {
            let prepared = try TcpRouteProfile.prepare(content: profile, allowFromLan: allowFromLan.value)
            try coreRunner.start(withConfigContent: prepared.runtimeContent, proxyPort: prepared.proxyPort)
            currentProxyPort.swap(prepared.proxyPort)
            return true
        } catch let error {
            currentProxyPort.swap(nil)
            Utils.alertError("Encounter an error when starting TcpRoute. \(error)")
            return false
        }
    }

    static func stopProxyServer() {
        coreRunner.stop()
    }

    private static func validateInstallation() -> Bool {
        do {
            _ = try TcpRouteRunner.resolveExecutable(in: profileFolder)
        } catch let error {
            Utils.alertError(error.localizedDescription)
            return false
        }
        let hasConfig = (try? FileManager.default.contentsOfDirectory(atPath: profileFolder))?.contains {
            ($0 as NSString).pathExtension.lowercased() == "toml"
        } ?? false
        if !hasConfig {
            Utils.alertError("Cannot find a TcpRoute TOML profile in \(profileFolder). Put config.toml there.")
            return false
        }
        return true
    }
}

private enum TcpRouteProfileError: LocalizedError {
    case missingAddress
    case invalidAddress

    var errorDescription: String? {
        switch self {
        case .missingAddress: return "TcpRoute profile must define addr."
        case .invalidAddress: return "TcpRoute profile addr must contain a valid port."
        }
    }
}

private struct TcpRouteProfile {
    let runtimeContent: String
    let proxyPort: UInt16

    static func prepare(content: String, allowFromLan: Bool) throws -> TcpRouteProfile {
        let pattern = "(?m)^\\s*addr\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else {
            throw TcpRouteProfileError.missingAddress
        }
        let range = NSRange(location: 0, length: (content as NSString).length)
        guard let match = expression.firstMatch(in: content, options: [], range: range),
              let addressRange = Range(match.range(at: 1), in: content) else {
            throw TcpRouteProfileError.missingAddress
        }
        let address = String(content[addressRange])
        guard let separator = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: separator)...]), port > 0 else {
            throw TcpRouteProfileError.invalidAddress
        }

        var runtimeContent = content
        if allowFromLan {
            let host = String(address[..<separator])
            if host == "127.0.0.1" || host == "localhost" {
                let replacement = address.replacingOccurrences(of: host, with: "0.0.0.0")
                runtimeContent = (runtimeContent as NSString).replacingCharacters(in: match.range(at: 1), with: replacement)
            }
        }
        return TcpRouteProfile(runtimeContent: runtimeContent, proxyPort: port)
    }
}

private final class TcpRouteRunner {
    private let onUnexpectedTermination: () -> Void
    private var process: Process?
    private var outputPipe: Pipe?
    private var runtimeConfigPath: String?
    private var stoppingProcess = false

    init(onUnexpectedTermination: @escaping () -> Void) {
        self.onUnexpectedTermination = onUnexpectedTermination
    }

    func start(withConfigContent content: String, proxyPort: UInt16) throws {
        stop()
        let executablePath = try TcpRouteRunner.resolveExecutable(in: ProfileManager.profileFolder)
        let configPath = try writeRuntimeConfig(content: content)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = ["-config", configPath]
        task.currentDirectoryURL = URL(fileURLWithPath: ProfileManager.profileFolder, isDirectory: true)

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DDLogInfo("[TcpRoute] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        task.terminationHandler = { process in
            DDLogInfo("[TcpRoute] terminated with status \(process.terminationStatus)")
            if self.process === process && !self.stoppingProcess {
                self.onUnexpectedTermination()
            }
        }
        do {
            try task.run()
        } catch let error {
            try? FileManager.default.removeItem(atPath: configPath)
            throw error
        }
        process = task
        outputPipe = pipe
        runtimeConfigPath = configPath
        DDLogInfo("[TcpRoute] started using \(configPath)")
        do {
            try waitUntilReady(process: task, port: proxyPort)
        } catch let error {
            stop()
            throw error
        }
    }

    private func waitUntilReady(process: Process, port: UInt16) throws {
        for _ in 0..<20 {
            if !process.isRunning {
                throw TcpRouteRunnerError.processExited
            }
            if isPortOpen(port: port) {
                return
            }
            usleep(100000)
        }
        throw TcpRouteRunnerError.portNotListening(port)
    }

    private func isPortOpen(port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = process, process.isRunning {
            stoppingProcess = true
            process.terminate()
            process.waitUntilExit()
            self.process = nil
            stoppingProcess = false
        }
        process = nil
        outputPipe = nil
        if let path = runtimeConfigPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        runtimeConfigPath = nil
    }

    static func resolveExecutable(in directory: String) throws -> String {
        let candidates = [
            (directory as NSString).appendingPathComponent("TcpRoute"),
            (directory as NSString).appendingPathComponent("TcpRoute-darwin-arm64"),
            (directory as NSString).appendingPathComponent("TcpRoute-darwin-amd64")
        ]
        if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return executable
        }
        throw NSError(domain: "SpechtLite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot find executable TcpRoute in \(directory)."])
    }

    private func writeRuntimeConfig(content: String) throws -> String {
        let runtimeFolder = ProfileManager.profileFolder
        let path = (runtimeFolder as NSString).appendingPathComponent(".spechtlite-runtime-\(UUID().uuidString).toml")
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}

private enum TcpRouteRunnerError: LocalizedError {
    case processExited
    case portNotListening(UInt16)

    var errorDescription: String? {
        switch self {
        case .processExited:
            return "TcpRoute exited before becoming ready."
        case .portNotListening(let port):
            return "TcpRoute did not listen on 127.0.0.1:\(port) within the startup timeout."
        }
    }
}
