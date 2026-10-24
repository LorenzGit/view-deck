import Darwin
import Foundation

struct SessionError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }

    static func invalid(_ message: String) -> SessionError {
        SessionError(code: "invalid_request", message: message)
    }
}

extension QAJSONValue {
    var foundationValue: Any {
        switch self {
        case .object(let values): return values.mapValues(\.foundationValue)
        case .array(let values): return values.map(\.foundationValue)
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }
}

struct SessionStartup: Codable {
    var configuration: QADeviceConfiguration
    var source: QASourceConfiguration
    var timeout: TimeInterval
    var idleTimeout: TimeInterval
    var waitSelector: String?
    var waitJavaScript: String?
    var prepareJavaScript: String?
    var settleDelay: TimeInterval
    var includeDeviceFrame: Bool
}

struct SessionManifest: Codable {
    var id: String
    var pid: Int32
    var state: String
    var createdAt: Date
    var error: String?
}

struct SessionRequest: Codable {
    var id = UUID().uuidString.lowercased()
    var method: String
    var params: [String: QAJSONValue]
    var deadline: Date
}

struct SessionResponse: Codable {
    var schemaVersion = 1
    var id: String
    var session: String
    var ok: Bool
    var result: QAJSONValue?
    var error: [String: String]?

    static func failure(id: String, session: String, error: Error) -> SessionResponse {
        SessionResponse(id: id, session: session, ok: false, result: nil,
                        error: ["code": (error as? SessionError)?.code ?? "operation_failed",
                                "message": error.localizedDescription])
    }
}

// Private per-user file RPC keeps page JavaScript and other users away from
// the control channel. No HTTP listener or desktop accessibility is needed.
struct SessionStore {
    let root: URL
    private let files = FileManager.default

    init(root: URL? = nil) throws {
        self.root = root ?? URL(fileURLWithPath: "/private/tmp/viewdeck-sessions-\(getuid())", isDirectory: true)
        try makePrivateDirectory(self.root)
    }

    static func canonicalID(_ id: String) throws -> String {
        guard let uuid = UUID(uuidString: id) else { throw SessionError.invalid("Invalid session ID.") }
        return uuid.uuidString.lowercased()
    }

    func folder(_ id: String) throws -> URL {
        let url = root.appendingPathComponent(try Self.canonicalID(id), isDirectory: true)
        try validatePrivateDirectory(url)
        return url
    }

    func create(id: String, startup: SessionStartup) throws -> URL {
        let url = root.appendingPathComponent(try Self.canonicalID(id), isDirectory: true)
        guard !files.fileExists(atPath: url.path) else { throw SessionError.invalid("Session already exists.") }
        try makePrivateDirectory(url)
        try makePrivateDirectory(url.appendingPathComponent("requests"))
        try makePrivateDirectory(url.appendingPathComponent("responses"))
        try write(startup, to: url.appendingPathComponent("startup.json"))
        return url
    }

    func allIDs() throws -> [String] {
        try files.contentsOfDirectory(atPath: root.path).filter { UUID(uuidString: $0) != nil }.sorted()
    }

    func remove(_ id: String) throws { try files.removeItem(at: folder(id)) }

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= 4 * 1024 * 1024 else {
            throw SessionError.invalid("Invalid or oversized session message.")
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func request(_ id: String, method: String, params: [String: QAJSONValue], timeout: TimeInterval) throws -> SessionResponse {
        let id = try Self.canonicalID(id)
        let directory = try folder(id)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = try read(SessionManifest.self, from: manifestURL)
        guard manifest.state != "closed", manifest.pid > 0, kill(manifest.pid, 0) == 0 else {
            throw SessionError(code: "session_closed", message: "Session is no longer running. Start a new session.")
        }
        let request = SessionRequest(method: method, params: params, deadline: Date().addingTimeInterval(timeout))
        let name = String(format: "%020llu", DispatchTime.now().uptimeNanoseconds) + "-" + request.id + ".json"
        let requestURL = directory.appendingPathComponent("requests").appendingPathComponent(name)
        let responseURL = directory.appendingPathComponent("responses").appendingPathComponent(request.id + ".json")
        try write(request, to: requestURL)
        defer {
            try? files.removeItem(at: requestURL)
            try? files.removeItem(at: responseURL)
        }
        while Date() < request.deadline.addingTimeInterval(0.5) {
            if files.fileExists(atPath: responseURL.path) {
                let response = try read(SessionResponse.self, from: responseURL)
                guard response.id == request.id, response.session == id else {
                    throw SessionError.invalid("Mismatched session response.")
                }
                return response
            }
            if kill(manifest.pid, 0) != 0 {
                throw SessionError(code: "session_closed", message: "The session process exited. Check \(directory.path)/session.log.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw SessionError(code: "timeout", message: "Session request timed out. Use session status or session stop to recover.")
    }

    private func makePrivateDirectory(_ url: URL) throws {
        if !files.fileExists(atPath: url.path) {
            try files.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try validatePrivateDirectory(url)
    }

    private func validatePrivateDirectory(_ url: URL) throws {
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw SessionError.invalid("Session directory must be owned by this user, private, and not a symlink: \(url.path)")
        }
    }
}

struct SessionInvocation {
    let method: String
    let session: String?
    var params: [String: QAJSONValue]
    let timeout: TimeInterval

    static func parse(_ arguments: [String]) throws -> SessionInvocation {
        var args = arguments
        guard var method = args.first else { throw SessionError.invalid("Missing session command. Run viewdeck session help.") }
        args.removeFirst()
        if method == "record" {
            guard let action = args.first, ["start", "stop"].contains(action) else {
                throw SessionError.invalid("Use session record start|stop <session>.")
            }
            method += "." + action
            args.removeFirst()
        }
        let allowed: [String: Set<String>] = [
            "list": [], "status": [], "stop": [], "inspect": [],
            "screenshot": ["output", "scale", "overwrite"],
            "click": ["selector", "x", "y", "button", "click-count"],
            "pointer": ["selector", "x", "y", "button", "action"],
            "drag": ["from-x", "from-y", "to-x", "to-y", "duration", "steps"],
            "key": ["key", "action", "modifiers", "hold", "key-code"],
            "type": ["selector", "text"], "scroll": ["selector", "x", "y"],
            "eval": ["js", "script-file"], "wait": ["selector", "js", "seconds"],
            "navigate": ["url", "file", "wait-for", "wait-js"], "reload": [],
            "configure": ["device", "orientation", "width", "height", "dpr", "include-device-frame", "hide-device-frame"],
            "record.start": ["output", "scale", "fps", "overwrite"], "record.stop": [],
            "request": ["input"]
        ]
        guard let options = allowed[method] else { throw SessionError.invalid("Unknown session command: \(method)") }
        var id: String?
        if method != "list" {
            guard let value = args.first else { throw SessionError.invalid("Missing session ID.") }
            id = try SessionStore.canonicalID(value)
            args.removeFirst()
        }
        var params: [String: QAJSONValue] = [:]
        var timeout: TimeInterval = 30
        let numbers: Set<String> = ["x", "y", "from-x", "from-y", "to-x", "to-y", "duration", "steps", "scale", "fps", "hold", "key-code", "click-count", "seconds", "width", "height", "dpr"]
        let switches: Set<String> = ["overwrite", "include-device-frame", "hide-device-frame"]
        var index = 0
        while index < args.count {
            let flag = args[index]
            if ["--help", "-h"].contains(flag) { throw SessionError(code: "help", message: "") }
            if flag == "--json" { index += 1; continue }
            guard flag.hasPrefix("--") else { throw SessionError.invalid("Unexpected argument: \(flag)") }
            let name = String(flag.dropFirst(2))
            guard options.contains(name) || name == "timeout" else { throw SessionError.invalid("Unsupported \(method) option: \(flag)") }
            if switches.contains(name) { params[name] = .bool(true); index += 1; continue }
            index += 1
            guard index < args.count else { throw SessionError.invalid("Missing value for \(flag)") }
            let value = args[index]
            if name == "timeout" || numbers.contains(name) {
                guard let number = Double(value), number.isFinite else { throw SessionError.invalid("\(flag) requires a finite number.") }
                if name == "timeout" { timeout = number } else { params[name] = .number(number) }
            } else if ["output", "file", "script-file", "input"].contains(name) {
                params[name] = .string(URL(fileURLWithPath: value).standardizedFileURL.path)
            } else { params[name] = .string(value) }
            index += 1
        }
        guard timeout >= 0.1, timeout <= 120 else { throw SessionError.invalid("--timeout must be between 0.1 and 120 seconds.") }
        params["timeout"] = .number(timeout)
        return SessionInvocation(method: method, session: id, params: params, timeout: timeout)
    }
}

enum SessionCommand {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            if arguments.isEmpty || ["help", "--help", "-h"].contains(arguments[0])
                || (arguments.count == 2 && ["--help", "-h"].contains(arguments[1]))
                || (arguments.first == "record" && arguments.count == 3 && ["--help", "-h"].contains(arguments[2])) {
                print(help)
                return 0
            }
            let store = try SessionStore()
            if arguments[0] == "_serve" {
                guard arguments.count == 2 else { throw SessionError.invalid("Invalid session host arguments.") }
                return try MainActor.assumeIsolated { try SessionHost.serve(id: arguments[1], store: store) }
            }
            if arguments[0] == "start" { return try start(Array(arguments.dropFirst()), store: store) }
            let command = try SessionInvocation.parse(arguments)
            if command.method == "list" {
                var values: [Any] = []
                for id in try store.allIDs() {
                    if let manifest = try? store.read(SessionManifest.self, from: store.folder(id).appendingPathComponent("manifest.json")) {
                        values.append(["session": id, "pid": manifest.pid,
                                       "state": kill(manifest.pid, 0) == 0 ? manifest.state : "stale"])
                    }
                }
                try printJSON(["schemaVersion": 1, "ok": true, "sessions": values])
                return 0
            }
            let id = command.session!
            var method = command.method
            var params = command.params
            if method == "request" {
                guard case .string(let input)? = params["input"],
                      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as? [String: Any],
                      let requestedMethod = object["method"] as? String else { throw SessionError.invalid("--input requires a JSON object with method and params.") }
                method = requestedMethod
                params = (object["params"] as? [String: Any] ?? [:]).mapValues(QAJSONValue.init(any:))
                params["timeout"] = .number(command.timeout)
            }
            if method == "stop", !FileManager.default.fileExists(atPath: store.root.appendingPathComponent(id).path) {
                try printJSON(["schemaVersion": 1, "ok": true, "session": id, "result": ["state": "closed"]])
                return 0
            }
            let manifest = try store.read(SessionManifest.self, from: store.folder(id).appendingPathComponent("manifest.json"))
            if method == "stop", manifest.state == "closed" || kill(manifest.pid, 0) != 0 {
                try store.remove(id)
                try printJSON(["schemaVersion": 1, "ok": true, "session": id, "result": ["state": "closed"]])
                return 0
            }
            let response = try store.request(id, method: method, params: params, timeout: command.timeout)
            try printJSON(try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)))
            if method == "stop", response.ok { try? store.remove(id) }
            return response.ok ? 0 : 1
        } catch {
            if (error as? SessionError)?.code == "help" { print(help); return 0 }
            let response = SessionResponse.failure(id: "", session: "", error: error)
            if let data = try? JSONEncoder().encode(response), let value = try? JSONSerialization.jsonObject(with: data) {
                try? printJSON(value)
            }
            return 2
        }
    }

    private static func start(_ arguments: [String], store: SessionStore) throws -> Int32 {
        var args = arguments
        var idleTimeout: TimeInterval = 1800
        if let index = args.firstIndex(of: "--idle-timeout") {
            guard index + 1 < args.count, let value = Double(args[index + 1]), value.isFinite, value >= 5, value <= 86400 else {
                throw SessionError.invalid("--idle-timeout must be between 5 and 86400 seconds.")
            }
            idleTimeout = value
            args.removeSubrange(index...(index + 1))
        }
        let invocation = try CLIInvocation.parse(["inspect"] + args)
        if invocation.operation == .help { print(help); return 0 }
        guard !invocation.showPreview, invocation.audioMode != .normal || !args.contains("--audio"),
              invocation.screenshotOutput == nil, invocation.videoOutput == nil, invocation.reportOutput == nil else {
            throw SessionError.invalid("Sessions are hidden and muted. Use session screenshot or session record after starting.")
        }
        guard let source = try CLISourceConfigurationFactory.make(invocation: invocation) else {
            throw SessionError.invalid("Session start requires a URL, --file, or --project.")
        }
        let startup = SessionStartup(
            configuration: try CLIConfigurationFactory.make(invocation: invocation),
            source: source,
            timeout: min(120, invocation.timeout), idleTimeout: idleTimeout,
            waitSelector: invocation.waitSelector, waitJavaScript: invocation.waitJavaScript,
            prepareJavaScript: invocation.prepareJavaScript, settleDelay: invocation.delay,
            includeDeviceFrame: invocation.includeDeviceFrame
        )
        let id = UUID().uuidString.lowercased()
        let directory = try store.create(id: id, startup: startup)
        let logURL = directory.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        process.arguments = ["session", "_serve", id]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        do { try process.run() } catch { try? store.remove(id); throw error }
        let deadline = Date().addingTimeInterval(startup.timeout + 5)
        while Date() < deadline {
            if let manifest = try? store.read(SessionManifest.self, from: directory.appendingPathComponent("manifest.json")) {
                if manifest.state == "ready" {
                    let response = try store.request(id, method: "status", params: [:], timeout: 5)
                    try printJSON(try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)))
                    return response.ok ? 0 : 1
                }
                if manifest.state == "failed" { throw SessionError(code: "startup_failed", message: "\(manifest.error ?? "Session failed"). Log: \(logURL.path)") }
            }
            if !process.isRunning { throw SessionError(code: "startup_failed", message: "Session exited before becoming ready. Log: \(logURL.path)") }
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning { process.terminate() }
        throw SessionError(code: "timeout", message: "Session startup timed out. Log: \(logURL.path)")
    }

    private static func printJSON(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        print(String(decoding: data, as: UTF8.self))
    }

    static let help = """
    Persistent hidden ViewDeck sessions. All results and errors are JSON.

      viewdeck session start <url> [device/layout/source options] [--idle-timeout 1800]
      viewdeck session list
      viewdeck session status <id>
      viewdeck session screenshot <id> --output /absolute/frame.png [--scale 3] [--overwrite]
      viewdeck session inspect <id>
      viewdeck session click <id> --selector '#play' | --x 120 --y 240
      viewdeck session pointer <id> --action down|move|up --x 120 --y 240
      viewdeck session drag <id> --from-x 50 --from-y 200 --to-x 250 --to-y 200
      viewdeck session key <id> --key ArrowRight [--action down|up|press] [--hold 0.2]
      viewdeck session type <id> --selector '#name' --text 'Player'
      viewdeck session scroll <id> --y 400
      viewdeck session eval <id> --js 'document.title' | --script-file /absolute/code.js
      viewdeck session wait <id> --selector '#ready' | --js 'window.ready' | --seconds 0.2
      viewdeck session navigate <id> --url http://localhost:5173/next
      viewdeck session reload <id>
      viewdeck session configure <id> --orientation landscape [--width 800 --height 600 --dpr 2]
      viewdeck session record start <id> --output /absolute/video.mp4 [--fps 30 --scale 3]
      viewdeck session record stop <id>
      viewdeck session request <id> --input /absolute/request.json
      viewdeck session stop <id>

    Coordinates use the main page's CSS pixels. Selectors resolve to visible element centers.
    Click, pointer, key and type use native WebKit input. Scroll and eval use JavaScript.
    State survives commands and navigation within a session. Sessions use isolated ephemeral storage.
    Start accepts URL, --file or --project, with the same device/layout/network flags as inspect.
    Default idle expiry is 30 minutes. Stop sessions when finished; stopping also saves active video.
    Generic requests have {"method":"click","params":{"selector":"#play"}}.
    """
}
