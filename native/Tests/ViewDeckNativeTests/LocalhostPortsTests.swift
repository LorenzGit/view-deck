import Foundation
import Network
import XCTest
@testable import ViewDeckCore

final class LocalhostPortsTests: XCTestCase {
    func testCustomNodeAndPythonServersGetOpenablePortsAndProjectNames() {
        for (name, command, folder) in [
            ("node", "node server.mjs", "/projects/gamojo-growth"),
            ("Python", "/usr/bin/python3 tools/serve.py", "/projects/bingo-themes")
        ] {
            var process = LocalhostProcess(
                pid: 123, parentPID: nil, processName: name, command: command,
                parentCommand: nil, workingDirectory: folder,
                endpoints: [LocalhostEndpoint(address: "127.0.0.1", port: 4195),
                            LocalhostEndpoint(address: "127.0.0.1", port: 4196)]
            )
            XCTAssertFalse(process.isDevelopmentServer)
            process.detectedHTTPPorts = [4195]
            XCTAssertTrue(process.isDevelopmentServer)
            XCTAssertEqual(process.openablePorts, [4195], "Do not open a non-HTTP companion port")
            XCTAssertEqual(process.displayName, URL(fileURLWithPath: folder).lastPathComponent)
            process.detectedHTTPPorts.insert(4196)
            XCTAssertEqual(process.openablePorts, [4195, 4196])
        }
    }

    func testKnownDevelopmentCommandsKeepOpenButtonsWithoutProbeResponse() {
        let process = LocalhostProcess(
            pid: 123, parentPID: nil, processName: "node", command: "node node_modules/.bin/vite",
            parentCommand: nil, workingDirectory: "/projects/game",
            endpoints: [LocalhostEndpoint(address: "*", port: 5173)]
        )
        XCTAssertTrue(process.isDevelopmentServer)
        XCTAssertEqual(process.openablePorts, [5173])
    }

    func testProbeUsesHEADAndRecognizesHTTPErrorResponses() throws {
        let server = try PortProbeFixture(response: "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop() }
        XCTAssertEqual(LocalhostHTTPProbe.detect(ports: [server.port]), [server.port])
        XCTAssertEqual(server.requests.first?.components(separatedBy: "\r\n").first, "HEAD / HTTP/1.1")
    }

    func testProbeDetectsRedirectWithoutFollowingIt() throws {
        let destination = try PortProbeFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        let redirect = try PortProbeFixture(response: "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(destination.port)/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { redirect.stop(); destination.stop() }
        XCTAssertEqual(LocalhostHTTPProbe.detect(ports: [redirect.port]), [redirect.port])
        XCTAssertTrue(destination.requests.isEmpty)
    }

    func testProbeExcludesNonHTTPAndUnresponsivePortsWithoutSerialTimeouts() throws {
        let http = try PortProbeFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        let nonHTTP = try PortProbeFixture(response: "This is not HTTP\r\n")
        let silent = try (0..<3).map { _ in try PortProbeFixture(response: nil) }
        defer { ([http, nonHTTP] + silent).forEach { $0.stop() } }
        let start = Date()
        let ports = Set(([http, nonHTTP] + silent).map(\.port))
        XCTAssertEqual(LocalhostHTTPProbe.detect(ports: ports, timeout: 0.5), [http.port])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
}

private final class PortProbeFixture {
    private let queue = DispatchQueue(label: "studio.viewdeck.tests.port-probe")
    private let listener: NWListener
    private let lock = NSLock()
    private var recordedRequests: [String] = []
    private var connections: [NWConnection] = []
    private(set) var port = 0

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    init(response: String?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock()
            self.connections.append(connection)
            self.lock.unlock()
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                if let data {
                    self.lock.lock()
                    self.recordedRequests.append(String(decoding: data, as: UTF8.self))
                    self.lock.unlock()
                }
                guard let response else { return }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, let boundPort = listener.port, boundPort.rawValue > 0 else {
            listener.cancel()
            throw NSError(domain: "PortProbeFixture", code: 1)
        }
        port = Int(boundPort.rawValue)
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let active = connections
        connections.removeAll()
        lock.unlock()
        active.forEach { $0.cancel() }
    }
}
