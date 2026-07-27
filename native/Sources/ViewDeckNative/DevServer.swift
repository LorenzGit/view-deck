import Darwin
import Foundation

enum DevServerState: String {
    case idle
    case starting
    case running
    case stopping
    case failed
}

protocol DevServerControllerDelegate: AnyObject {
    func devServerStateChanged(_ state: DevServerState, url: URL?)
    func devServerDidOutput(_ line: String, isError: Bool)
}

enum DevServerURLDetector {
    static func stripTerminalCodes(_ value: String) -> String {
        let pattern = #"\u001B(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007]*(?:\u0007|\u001B\\))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }

    static func findURL(in rawValue: String) -> URL? {
        let value = stripTerminalCodes(rawValue)
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::\]|[a-zA-Z0-9.-]+):\d+(?:/[^\s]*)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let swiftRange = Range(match.range, in: value) else { return nil }
        var candidate = String(value[swiftRange])
        candidate = candidate.replacingOccurrences(of: "0.0.0.0", with: "localhost")
        candidate = candidate.replacingOccurrences(of: "[::]", with: "localhost")
        return URL(string: candidate)
    }
}

enum DevServerPortConflictDetector {
    static func findPort(in rawValue: String) -> Int? {
        let value = DevServerURLDetector.stripTerminalCodes(rawValue)
        let patterns = [
            #"(?i)\bport\s+(\d{1,5})\s+(?:is\s+)?already\s+in\s+use\b"#,
            #"(?i)\bEADDRINUSE\b[^\r\n]*?:(\d{1,5})\b"#,
            #"(?i)\baddress already in use\b[^\r\n]*?:(\d{1,5})\b"#
        ]

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..., in: value)
            guard let match = expression.firstMatch(in: value, range: range),
                  match.numberOfRanges > 1,
                  let portRange = Range(match.range(at: 1), in: value),
                  let port = Int(value[portRange]),
                  (1...65_535).contains(port) else { continue }
            return port
        }
        return nil
    }
}

enum DevServerEnvironment {
    static func make(
        from base: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var environment = base
        let existing = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        var candidates = existing + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDirectory.appendingPathComponent(".volta/bin").path,
            homeDirectory.appendingPathComponent(".asdf/shims").path,
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent(".local/share/mise/shims").path,
            homeDirectory.appendingPathComponent(".local/share/fnm/aliases/default/bin").path
        ]

        let nvmVersions = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.map {
                $0.appendingPathComponent("bin", isDirectory: true).path
            })
        }

        var seen = Set<String>()
        environment["PATH"] = candidates.filter { seen.insert($0).inserted }.joined(separator: ":")
        environment["FORCE_COLOR"] = "1"
        return environment
    }

    static func executable(named name: String, environment: [String: String]) -> URL? {
        let fileManager = FileManager.default
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

enum DevServerPortOverride {
    static func isSupported(command: String) -> Bool {
        let commandWithoutSequentialAnd = command.replacingOccurrences(of: "&&", with: "")
        guard !command.contains("|") && !commandWithoutSequentialAnd.contains("&") else { return false }
        guard var segment = command
            .components(separatedBy: ";")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !segment.isEmpty else { return false }

        if let range = segment.range(of: "&&", options: .backwards) {
            segment = String(segment[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var tokens = segment
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                String(token).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
        guard !tokens.isEmpty else { return false }

        while let first = tokens.first, isEnvironmentAssignment(first) {
            tokens.removeFirst()
        }
        if let first = tokens.first, ["env", "cross-env"].contains(executableName(first)) {
            tokens.removeFirst()
            while let assignment = tokens.first, isEnvironmentAssignment(assignment) {
                tokens.removeFirst()
            }
        }
        if let first = tokens.first, ["npx", "bunx"].contains(executableName(first)) {
            tokens.removeFirst()
        } else if let first = tokens.first, ["npm", "pnpm", "yarn", "bun"].contains(executableName(first)) {
            tokens.removeFirst()
            if let subcommand = tokens.first, ["exec", "dlx", "x"].contains(subcommand) {
                tokens.removeFirst()
            }
        }
        if let first = tokens.first, ["node", "nodejs"].contains(executableName(first)) {
            tokens.removeFirst()
        }
        guard let executable = tokens.first.map(executableName) else { return false }

        switch executable {
        case "vite", "vite.js", "vite.mjs", "astro", "nuxt", "nuxi", "parcel", "webpack-dev-server":
            return true
        case "next":
            return tokens.dropFirst().first.map { ["dev", "start"].contains($0) } ?? false
        case "webpack":
            return tokens.dropFirst().first == "serve"
        case "ng":
            return tokens.dropFirst().first == "serve"
        case "vue-cli-service":
            return tokens.dropFirst().first == "serve"
        case "gatsby":
            return tokens.dropFirst().first.map { ["develop", "serve"].contains($0) } ?? false
        default:
            return false
        }
    }

    private static func executableName(_ value: String) -> String {
        URL(fileURLWithPath: value).lastPathComponent.lowercased()
    }

    private static func isEnvironmentAssignment(_ value: String) -> Bool {
        guard let separator = value.firstIndex(of: "=") else { return false }
        let name = value[..<separator]
        guard !name.isEmpty else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

enum DevServerLaunchError: LocalizedError {
    case npmNotFound
    case processStillRunning

    var errorDescription: String? {
        switch self {
        case .npmNotFound:
            return "npm was not found. Install Node.js with Homebrew or make npm available in /opt/homebrew/bin or /usr/local/bin."
        case .processStillRunning:
            return "Wait for the previous process to stop and release its port before starting another one."
        }
    }
}

final class DevServerController {
    private enum PortOverrideStyle {
        case npmArguments
        case shellCommand
    }

    private struct LaunchConfiguration {
        let executable: URL
        var arguments: [String]
        let folder: URL
        let environment: [String: String]
        let runningOnStart: Bool
        let portOverrideStyle: PortOverrideStyle?

        func overridingPort(with port: Int) -> LaunchConfiguration {
            var copy = self
            switch portOverrideStyle {
            case .npmArguments:
                copy.arguments += ["--", "--port", String(port)]
            case .shellCommand:
                if copy.arguments.indices.contains(1) {
                    copy.arguments[1] += " --port \(port)"
                }
            case nil:
                break
            }
            return copy
        }
    }

    weak var delegate: DevServerControllerDelegate?
    private let baseEnvironment: [String: String]
    private(set) var state: DevServerState = .idle
    private(set) var serverURL: URL?
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var bufferedOutput = ""
    private var userRequestedStop = false
    private var activeConfiguration: LaunchConfiguration?
    private var pendingRelaunch: LaunchConfiguration?
    private var occupiedPortsBeforeLaunch: Set<Int> = []
    private var didAutomaticallyRetryPort = false
    private var outputGeneration = UUID()

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        baseEnvironment = environment
    }

    func scripts(in folder: URL) -> [String] {
        let packageURL = folder.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any] else { return [] }
        let names = scripts.keys.sorted()
        if names.contains("dev") { return ["dev"] + names.filter { $0 != "dev" } }
        return names
    }

    func start(folder: URL, script: String) throws {
        let environment = DevServerEnvironment.make(from: baseEnvironment)
        guard let npmURL = DevServerEnvironment.executable(named: "npm", environment: environment) else {
            updateState(.failed)
            throw DevServerLaunchError.npmNotFound
        }

        let command = scriptCommand(named: script, in: folder)
        try launch(LaunchConfiguration(
            executable: npmURL,
            arguments: ["run", script],
            folder: folder,
            environment: environment,
            runningOnStart: false,
            portOverrideStyle: command.map(DevServerPortOverride.isSupported) == true ? .npmArguments : nil
        ))
    }

    func startCommand(folder: URL, command: String) throws {
        try launch(LaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", command],
            folder: folder,
            environment: DevServerEnvironment.make(from: baseEnvironment),
            runningOnStart: true,
            portOverrideStyle: DevServerPortOverride.isSupported(command: command) ? .shellCommand : nil
        ))
    }

    private func launch(_ configuration: LaunchConfiguration) throws {
        guard process?.isRunning != true else {
            throw DevServerLaunchError.processStillRunning
        }
        occupiedPortsBeforeLaunch = (try? LocalhostPortScanner.listeningPorts()) ?? []
        didAutomaticallyRetryPort = false
        pendingRelaunch = nil
        activeConfiguration = configuration
        try run(configuration, notifyStarting: true)
    }

    private func run(_ configuration: LaunchConfiguration, notifyStarting: Bool) throws {
        teardownPipes()
        process = nil
        serverURL = nil
        bufferedOutput = ""
        userRequestedStop = false
        activeConfiguration = configuration
        let generation = UUID()
        outputGeneration = generation
        if notifyStarting { updateState(.starting) }

        let child = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        child.executableURL = configuration.executable
        child.arguments = configuration.arguments
        child.currentDirectoryURL = configuration.folder
        child.standardOutput = stdout
        child.standardError = stderr
        child.environment = configuration.environment

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isError: false, generation: generation)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isError: true, generation: generation)
        }
        child.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                self.teardownPipes()
                self.process = nil
                if let relaunch = self.pendingRelaunch {
                    self.pendingRelaunch = nil
                    do {
                        try self.run(relaunch, notifyStarting: false)
                    } catch {
                        self.activeConfiguration = nil
                        self.updateState(.failed)
                        self.delegate?.devServerDidOutput(
                            "Could not restart the server on a free port: \(error.localizedDescription)",
                            isError: true
                        )
                    }
                    return
                }
                let stoppedCleanly = self.userRequestedStop || process.terminationStatus == 0
                self.userRequestedStop = false
                if stoppedCleanly {
                    self.activeConfiguration = nil
                    self.updateState(.idle)
                    return
                }

                // Give the final stderr/stdout readability callback a chance to
                // recognize EADDRINUSE and schedule a retry before surfacing failure.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self,
                          self.outputGeneration == generation,
                          self.process == nil,
                          self.pendingRelaunch == nil else { return }
                    self.activeConfiguration = nil
                    self.updateState(.failed)
                }
            }
        }

        do {
            try child.run()
        } catch {
            updateState(.failed)
            throw error
        }
        _ = setpgid(child.processIdentifier, child.processIdentifier)
        process = child
        stdoutPipe = stdout
        stderrPipe = stderr
        if configuration.runningOnStart { updateState(.running) }
    }

    func stop() {
        pendingRelaunch = nil
        outputGeneration = UUID()
        guard let process, process.isRunning else {
            teardownPipes()
            self.process = nil
            activeConfiguration = nil
            if state != .idle { updateState(.idle) }
            return
        }
        userRequestedStop = true
        updateState(.stopping)
        terminateCurrentProcess()
    }

    func ownsProcess(_ pid: pid_t) -> Bool {
        guard let process, process.isRunning else { return false }
        let rootPID = process.processIdentifier
        return pid == rootPID || descendantPIDs(of: rootPID).contains(pid)
    }

    private func consume(_ data: Data, isError: Bool, generation: UUID) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.outputGeneration == generation else { return }
            self.bufferedOutput += chunk
            let clean = DevServerURLDetector.stripTerminalCodes(chunk)
            clean.split(whereSeparator: \.isNewline).forEach {
                self.delegate?.devServerDidOutput(String($0), isError: isError)
            }
            guard self.state != .stopping,
                  self.pendingRelaunch == nil,
                  self.serverURL == nil else { return }

            if let port = DevServerPortConflictDetector.findPort(in: self.bufferedOutput),
               self.retryOnFreePortIfNeeded(requestedPort: port) { return }
            guard let url = DevServerURLDetector.findURL(in: self.bufferedOutput) else { return }
            if let port = url.port, self.retryOnFreePortIfNeeded(requestedPort: port) { return }
            self.serverURL = url
            self.updateState(.running)
        }
    }

    private func retryOnFreePortIfNeeded(requestedPort: Int) -> Bool {
        guard pendingRelaunch == nil,
              !didAutomaticallyRetryPort,
              occupiedPortsBeforeLaunch.contains(requestedPort),
              let configuration = activeConfiguration,
              configuration.portOverrideStyle != nil else { return false }

        let occupiedNow = (try? LocalhostPortScanner.listeningPorts()) ?? occupiedPortsBeforeLaunch
        guard let availablePort = LocalhostPortSelection.nextAvailable(
            after: requestedPort,
            occupied: occupiedPortsBeforeLaunch.union(occupiedNow)
        ) else { return false }

        didAutomaticallyRetryPort = true
        pendingRelaunch = configuration.overridingPort(with: availablePort)
        serverURL = nil
        bufferedOutput = ""
        delegate?.devServerDidOutput(
            "Port \(requestedPort) was already in use; restarting this server on port \(availablePort)…",
            isError: false
        )
        updateState(.starting)
        if process?.isRunning == true {
            terminateCurrentProcess()
        } else if let relaunch = pendingRelaunch {
            pendingRelaunch = nil
            do {
                try run(relaunch, notifyStarting: false)
            } catch {
                activeConfiguration = nil
                updateState(.failed)
                delegate?.devServerDidOutput(
                    "Could not restart the server on a free port: \(error.localizedDescription)",
                    isError: true
                )
            }
        }
        return true
    }

    private func updateState(_ next: DevServerState) {
        state = next
        delegate?.devServerStateChanged(next, url: serverURL)
    }

    private func teardownPipes() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func terminateCurrentProcess() {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        let processTree = descendantPIDs(of: pid) + [pid]
        for target in processTree.reversed() { _ = kill(target, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
            for target in processTree.reversed() where kill(target, 0) == 0 {
                _ = kill(target, SIGKILL)
            }
        }
    }

    private func scriptCommand(named script: String, in folder: URL) -> String? {
        let packageURL = folder.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: String] else { return nil }
        return scripts[script]
    }

    private func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        let snapshot = Process()
        let output = Pipe()
        snapshot.executableURL = URL(fileURLWithPath: "/bin/ps")
        snapshot.arguments = ["-axo", "pid=,ppid="]
        snapshot.standardOutput = output
        snapshot.standardError = FileHandle.nullDevice
        guard (try? snapshot.run()) != nil else { return [] }
        snapshot.waitUntilExit()
        guard let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return [] }

        var children: [pid_t: [pid_t]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count == 2, let pid = pid_t(columns[0]), let parent = pid_t(columns[1]) else { continue }
            children[parent, default: []].append(pid)
        }

        var descendants: [pid_t] = []
        var pending = children[rootPID] ?? []
        while let pid = pending.popLast() {
            descendants.append(pid)
            pending.append(contentsOf: children[pid] ?? [])
        }
        return descendants
    }
}
