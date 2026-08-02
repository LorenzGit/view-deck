import Foundation
import Network
import XCTest
@testable import ViewDeckCore

final class NetworkShapingTests: XCTestCase {
    func testProxyAppliesRoundTripLatencyAndDownloadBandwidth() throws {
        let payload = Data(repeating: 0x5A, count: 8 * 1_024)
        let origin = try TestOriginServer(payload: payload)
        defer { origin.stop() }

        let configuration = NetworkShapingConfiguration(
            enabled: true,
            roundTripTimeMilliseconds: 160,
            jitterMilliseconds: 0,
            downloadKilobitsPerSecond: 64,
            uploadKilobitsPerSecond: 0,
            offline: false,
            seed: 42
        )
        let proxy = NetworkShapingProxy(configuration: configuration)
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let completed = expectation(description: "SOCKS tunnel delivers the shaped payload")
        let queue = DispatchQueue(label: "studio.viewdeck.tests.network-client")
        let client = NWConnection(host: "127.0.0.1", port: proxyPort, using: .tcp)
        let reader = TestConnectionByteReader(connection: client)
        let startedAt = ProcessInfo.processInfo.systemUptime
        var connectReplyAt: TimeInterval?

        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.send(content: Data([5, 1, 0]), completion: .contentProcessed { error in
                XCTAssertNil(error)
                reader.read(count: 2) { greeting in
                    XCTAssertEqual(greeting, Data([5, 0]))
                    let port = origin.port.rawValue
                    let request = Data([
                        5, 1, 0, 1, 127, 0, 0, 1,
                        UInt8(port >> 8), UInt8(port & 0xFF)
                    ])
                    client.send(content: request, completion: .contentProcessed { error in
                        XCTAssertNil(error)
                        reader.read(count: 10) { reply in
                            XCTAssertEqual(reply?.prefix(2), Data([5, 0]))
                            connectReplyAt = ProcessInfo.processInfo.systemUptime
                            reader.read(count: payload.count) { received in
                                XCTAssertEqual(received, payload)
                                completed.fulfill()
                            }
                        }
                    })
                }
            })
        }
        client.start(queue: queue)

        wait(for: [completed], timeout: 4)
        client.cancel()
        let finishedAt = ProcessInfo.processInfo.systemUptime
        let connectDelay = try XCTUnwrap(connectReplyAt) - startedAt
        XCTAssertGreaterThanOrEqual(connectDelay, 0.13)
        XCTAssertGreaterThanOrEqual(finishedAt - connectDelay - startedAt, 0.95)

        let report = proxy.report(configuration: configuration)
        XCTAssertEqual(report["downloadedBytes"] as? UInt64, UInt64(payload.count))
        XCTAssertEqual(report["trafficObserved"] as? Bool, true)
        XCTAssertEqual(report["implementation"] as? String, "loopbackSOCKSv5Proxy")
        XCTAssertEqual(report["http3QUICShaped"] as? Bool, false)
    }

    func testLocalHTTPURLUsesShapedTCPBridge() throws {
        let payload = Data("local bridge".utf8)
        let origin = try TestOriginServer(payload: payload)
        defer { origin.stop() }

        var configuration = NetworkShapingConfiguration.disabled
        configuration.enabled = true
        configuration.roundTripTimeMilliseconds = 120
        configuration.jitterMilliseconds = 0
        configuration.downloadKilobitsPerSecond = 0
        configuration.uploadKilobitsPerSecond = 0
        let proxy = NetworkShapingProxy(configuration: configuration)
        _ = try proxy.start()
        defer { proxy.stop() }

        let source = try XCTUnwrap(URL(string: "http://localhost:\(origin.port.rawValue)/fixture"))
        let shaped = try proxy.shapedURL(for: source)
        XCTAssertEqual(shaped.host, "127.0.0.1")
        let bridgePortValue = try XCTUnwrap(shaped.port)
        let bridgePort = try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(bridgePortValue)))
        XCTAssertNotEqual(bridgePort, origin.port)
        XCTAssertEqual(shaped.path, "/fixture")

        let completed = expectation(description: "local bridge delivers the shaped payload")
        let client = NWConnection(host: "127.0.0.1", port: bridgePort, using: .tcp)
        let reader = TestConnectionByteReader(connection: client)
        let startedAt = ProcessInfo.processInfo.systemUptime
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            reader.read(count: payload.count) { received in
                XCTAssertEqual(received, payload)
                completed.fulfill()
            }
        }
        client.start(queue: DispatchQueue(label: "studio.viewdeck.tests.local-bridge-client"))
        wait(for: [completed], timeout: 2)
        client.cancel()

        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - startedAt, 0.15)
        let report = proxy.report(configuration: configuration)
        XCTAssertEqual(report["implementation"] as? String, "loopbackTCPBridge+SOCKSv5Proxy")
        XCTAssertEqual(report["localBridgeHost"] as? String, "127.0.0.1")
        XCTAssertEqual(report["downloadedBytes"] as? UInt64, UInt64(payload.count))
        XCTAssertEqual(report["trafficObserved"] as? Bool, true)
    }
}

private final class TestOriginServer {
    private let queue: DispatchQueue
    private let listener: NWListener
    private let payload: Data
    let port: NWEndpoint.Port

    init(payload: Data) throws {
        let queue = DispatchQueue(label: "studio.viewdeck.tests.network-origin")
        self.queue = queue
        self.payload = payload
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        var readyPort: NWEndpoint.Port?
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                readyPort = listener.port
                ready.signal()
            }
        }
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                connection.send(
                    content: payload,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in }
                )
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, let readyPort else {
            throw NetworkShapingError.listenerTimedOut
        }
        port = readyPort
    }

    func stop() {
        listener.cancel()
    }
}

private final class TestConnectionByteReader {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func read(count: Int, completion: @escaping (Data?) -> Void) {
        read(count: count, accumulated: Data(), completion: completion)
    }

    private func read(count: Int, accumulated: Data, completion: @escaping (Data?) -> Void) {
        guard accumulated.count < count else {
            completion(accumulated)
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: count - accumulated.count
        ) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                completion(nil)
                return
            }
            var next = accumulated
            if let data { next.append(data) }
            guard !isComplete || next.count == count else {
                completion(nil)
                return
            }
            self.read(count: count, accumulated: next, completion: completion)
        }
    }
}
