import Foundation

struct LocalhostEndpoint: Equatable, Hashable {
    let address: String
    let port: Int

    var label: String {
        address == "*" ? "*:\(port)" : "\(address):\(port)"
    }
}

struct LocalhostProcess: Equatable, Identifiable {
    let pid: pid_t
    let parentPID: pid_t?
    let processName: String
    let command: String
    let parentCommand: String?
    let workingDirectory: String?
    let endpoints: [LocalhostEndpoint]
    var detectedHTTPPorts: Set<Int> = []

    var id: pid_t { pid }

    var ports: [Int] {
        Array(Set(endpoints.map(\.port))).sorted()
    }

    var displayName: String {
        guard isDevelopmentServer,
              let workingDirectory,
              !workingDirectory.isEmpty else { return processName }
        let folderName = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return folderName.isEmpty || folderName == "/" ? processName : folderName
    }

    var isDevelopmentServer: Bool {
        !openablePorts.isEmpty
    }

    var openablePorts: [Int] {
        ports.filter {
            detectedHTTPPorts.contains($0) || (detectedHTTPPorts.isEmpty && matchesDevelopmentCommand)
        }
    }

    private var matchesDevelopmentCommand: Bool {
        let description = [processName, command, parentCommand, workingDirectory]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return description.contains("node_modules/.bin/")
            || description.contains("npm run")
            || description.contains("pnpm ")
            || description.contains("yarn ")
            || description.contains("bun ")
            || description.contains(" vite")
            || description.contains(" next")
            || description.contains("webpack")
            || description.contains("parcel")
            || description.contains("astro")
            || description.contains("nuxt")
            || description.contains("python -m http.server")
    }
}

enum LocalhostPortScanner {
    struct ListenerRecord: Equatable {
        let pid: pid_t
        let processName: String
        let endpoint: LocalhostEndpoint
    }

    struct ProcessRecord: Equatable {
        let parentPID: pid_t
        let command: String
    }

    static func scan() throws -> [LocalhostProcess] {
        let listenerOutput = try run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]
        )
        let processOutput = try run(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,command="]
        )
        let listeners = parseListeners(listenerOutput)
        let processTable = parseProcessTable(processOutput)
        let grouped = Dictionary(grouping: listeners, by: \.pid)

        let httpPorts = LocalhostHTTPProbe.detect(ports: Set(listeners.map(\.endpoint.port)))
        return grouped.map { pid, records in
            let process = processTable[pid]
            let parent = process.flatMap { processTable[$0.parentPID] }
            return LocalhostProcess(
                pid: pid,
                parentPID: process?.parentPID,
                processName: records.first?.processName ?? "process",
                command: process?.command ?? records.first?.processName ?? "process",
                parentCommand: parent?.command,
                workingDirectory: workingDirectory(for: pid),
                endpoints: Array(Set(records.map(\.endpoint))).sorted {
                    $0.port == $1.port ? $0.address < $1.address : $0.port < $1.port
                },
                detectedHTTPPorts: httpPorts.intersection(records.map(\.endpoint.port))
            )
        }
        .sorted {
            if $0.isDevelopmentServer != $1.isDevelopmentServer { return $0.isDevelopmentServer }
            return ($0.ports.first ?? .max) < ($1.ports.first ?? .max)
        }
    }

    static func listeningPorts() throws -> Set<Int> {
        let output = try run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]
        )
        return Set(parseListeners(output).map(\.endpoint.port))
    }

    static func parseListeners(_ output: String) -> [ListenerRecord] {
        var pid: pid_t?
        var processName = "process"
        var listeners: [ListenerRecord] = []

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p": pid = pid_t(value)
            case "c": processName = value
            case "n":
                guard let pid, let endpoint = parseEndpoint(value) else { continue }
                listeners.append(ListenerRecord(pid: pid, processName: processName, endpoint: endpoint))
            default: continue
            }
        }
        return listeners
    }

    static func parseProcessTable(_ output: String) -> [pid_t: ProcessRecord] {
        var table: [pid_t: ProcessRecord] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard columns.count == 3,
                  let pid = pid_t(columns[0]),
                  let parentPID = pid_t(columns[1]) else { continue }
            table[pid] = ProcessRecord(parentPID: parentPID, command: String(columns[2]))
        }
        return table
    }

    static func collidingPorts(in processes: [LocalhostProcess]) -> Set<Int> {
        var owners: [Int: Set<pid_t>] = [:]
        for process in processes {
            for port in process.ports { owners[port, default: []].insert(process.pid) }
        }
        return Set(owners.compactMap { $0.value.count > 1 ? $0.key : nil })
    }

    private static func parseEndpoint(_ value: String) -> LocalhostEndpoint? {
        guard let separator = value.lastIndex(of: ":"),
              let port = Int(value[value.index(after: separator)...]) else { return nil }
        var address = String(value[..<separator])
        if address.hasPrefix("[") && address.hasSuffix("]") {
            address.removeFirst()
            address.removeLast()
        }
        return LocalhostEndpoint(address: address, port: port)
    }

    private static func workingDirectory(for pid: pid_t) -> String? {
        guard let output = try? run(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        ) else { return nil }
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("n") })
            .map { String($0.dropFirst()) }
    }

    private static func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// A HEAD response identifies custom web servers without relying on their
// executable or script names. Probe in parallel so non-HTTP listeners cannot
// stall the port list, and never follow redirects away from localhost.
final class LocalhostHTTPProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var detectedPorts: Set<Int> = []

    static func detect(ports: Set<Int>, timeout: TimeInterval = 1) -> Set<Int> {
        guard !ports.isEmpty else { return [] }
        let probe = LocalhostHTTPProbe()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let group = DispatchGroup()
        for port in ports {
            guard let url = URL(string: "http://localhost:\(port)/") else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: timeout)
            request.httpMethod = "HEAD"
            group.enter()
            session.dataTask(with: request) { _, response, _ in
                if response is HTTPURLResponse {
                    probe.lock.lock()
                    probe.detectedPorts.insert(port)
                    probe.lock.unlock()
                }
                group.leave()
            }.resume()
        }
        _ = group.wait(timeout: .now() + timeout + 0.5)
        probe.lock.lock()
        defer { probe.lock.unlock() }
        return probe.detectedPorts
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum LocalhostPortSelection {
    static func nextAvailable(after requestedPort: Int, occupied: Set<Int>) -> Int? {
        let firstUserPort = 1024
        let lastPort = 65_535
        let nextPort = max(firstUserPort, requestedPort + 1)

        if nextPort <= lastPort,
           let available = (nextPort...lastPort).first(where: { !occupied.contains($0) }) {
            return available
        }

        let wrapEnd = min(lastPort, max(firstUserPort, requestedPort) - 1)
        guard wrapEnd >= firstUserPort else { return nil }
        return (firstUserPort...wrapEnd).first(where: { !occupied.contains($0) })
    }
}
