import Darwin
import Foundation
import Network

struct NetworkShapingConfiguration: Codable, Equatable {
    static let maximumJSONSafeSeed: UInt64 = 9_007_199_254_740_991

    var enabled: Bool
    var roundTripTimeMilliseconds: Double
    var jitterMilliseconds: Double
    var downloadKilobitsPerSecond: Double
    var uploadKilobitsPerSecond: Double
    var offline: Bool
    var seed: UInt64

    static let disabled = NetworkShapingConfiguration(
        enabled: false,
        roundTripTimeMilliseconds: 300,
        jitterMilliseconds: 30,
        downloadKilobitsPerSecond: 1_600,
        uploadKilobitsPerSecond: 750,
        offline: false,
        seed: 42
    )

    var normalized: NetworkShapingConfiguration {
        NetworkShapingConfiguration(
            enabled: enabled,
            roundTripTimeMilliseconds: max(0, roundTripTimeMilliseconds),
            jitterMilliseconds: max(0, jitterMilliseconds),
            downloadKilobitsPerSecond: max(0, downloadKilobitsPerSecond),
            uploadKilobitsPerSecond: max(0, uploadKilobitsPerSecond),
            offline: offline,
            seed: min(seed, Self.maximumJSONSafeSeed)
        )
    }

    var reportDictionary: [String: Any] {
        [
            "enabled": enabled,
            "roundTripTimeMilliseconds": roundTripTimeMilliseconds,
            "jitterMilliseconds": jitterMilliseconds,
            "downloadKilobitsPerSecond": downloadKilobitsPerSecond,
            "uploadKilobitsPerSecond": uploadKilobitsPerSecond,
            "offline": offline,
            "seed": seed
        ]
    }
}

enum NetworkShapingError: LocalizedError {
    case listenerFailed(String)
    case listenerTimedOut
    case listenerHasNoPort
    case localBridgeRequiresPort
    case localBridgeUnavailable(Int, String)

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let message):
            return "The network shaping proxy could not start: \(message)"
        case .listenerTimedOut:
            return "The network shaping proxy did not become ready in time."
        case .listenerHasNoPort:
            return "The network shaping proxy started without a local port."
        case .localBridgeRequiresPort:
            return "Local network shaping requires an HTTP URL with a valid port."
        case .localBridgeUnavailable(let port, let message):
            return "The local network shaping bridge for port \(port) could not start: \(message)"
        }
    }
}

private final class NetworkShapingState {
    struct Statistics {
        var acceptedConnections = 0
        var activeConnections = 0
        var uploadedBytes: UInt64 = 0
        var downloadedBytes: UInt64 = 0
    }

    private let lock = NSLock()
    private var configuration: NetworkShapingConfiguration
    private var statistics = Statistics()

    init(configuration: NetworkShapingConfiguration) {
        self.configuration = configuration.normalized
    }

    func snapshot() -> NetworkShapingConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    func update(_ configuration: NetworkShapingConfiguration) {
        lock.lock()
        self.configuration = configuration.normalized
        lock.unlock()
    }

    func connectionOpened() {
        lock.lock()
        statistics.acceptedConnections += 1
        statistics.activeConnections += 1
        lock.unlock()
    }

    func connectionClosed() {
        lock.lock()
        statistics.activeConnections = max(0, statistics.activeConnections - 1)
        lock.unlock()
    }

    func transferred(byteCount: Int, direction: TrafficDirection) {
        lock.lock()
        if direction == .upload {
            statistics.uploadedBytes += UInt64(byteCount)
        } else {
            statistics.downloadedBytes += UInt64(byteCount)
        }
        lock.unlock()
    }

    func statisticsSnapshot() -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        return statistics
    }
}

private enum TrafficDirection {
    case upload
    case download
}

private struct SeededRandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func nextUnitInterval() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state) / Double(UInt64.max)
    }
}

private final class TrafficScheduler {
    private let queue: DispatchQueue
    private let state: NetworkShapingState
    private let direction: TrafficDirection
    private var random: SeededRandomNumberGenerator
    private var nextDeliveryUptime: TimeInterval = 0

    init(
        queue: DispatchQueue,
        state: NetworkShapingState,
        direction: TrafficDirection,
        seed: UInt64
    ) {
        self.queue = queue
        self.state = state
        self.direction = direction
        random = SeededRandomNumberGenerator(seed: seed)
    }

    func schedule(byteCount: Int, delivery: @escaping () -> Void) {
        let configuration = state.snapshot()
        let now = ProcessInfo.processInfo.systemUptime
        let jitter = configuration.jitterMilliseconds == 0
            ? 0
            : (random.nextUnitInterval() * 2 - 1) * configuration.jitterMilliseconds
        let oneWayDelay = max(
            0,
            configuration.roundTripTimeMilliseconds / 2 + jitter
        ) / 1_000
        let kilobitsPerSecond = direction == .upload
            ? configuration.uploadKilobitsPerSecond
            : configuration.downloadKilobitsPerSecond
        let transmissionDuration = kilobitsPerSecond > 0
            ? Double(byteCount * 8) / (kilobitsPerSecond * 1_000)
            : 0
        let transmissionStart = max(now + oneWayDelay, nextDeliveryUptime)
        let deliveryUptime = transmissionStart + transmissionDuration
        nextDeliveryUptime = deliveryUptime
        queue.asyncAfter(deadline: .now() + max(0, deliveryUptime - now), execute: delivery)
    }
}

private final class TrafficRelay {
    private static let chunkSize = 4 * 1_024
    private static let maximumBufferedBytes = 256 * 1_024

    private let source: NWConnection
    private let destination: NWConnection
    private let scheduler: TrafficScheduler
    private let state: NetworkShapingState
    private let direction: TrafficDirection
    private let onError: () -> Void
    private let onComplete: () -> Void
    private var receivePending = false
    private var sourceEnded = false
    private var cancelled = false
    private var bufferedBytes = 0
    private var pendingSends = 0

    init(
        source: NWConnection,
        destination: NWConnection,
        scheduler: TrafficScheduler,
        state: NetworkShapingState,
        direction: TrafficDirection,
        onError: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.source = source
        self.destination = destination
        self.scheduler = scheduler
        self.state = state
        self.direction = direction
        self.onError = onError
        self.onComplete = onComplete
    }

    func start() {
        receiveNextChunk()
    }

    func cancel() {
        cancelled = true
    }

    private func receiveNextChunk() {
        guard !cancelled,
              !sourceEnded,
              !receivePending,
              bufferedBytes < Self.maximumBufferedBytes else { return }
        receivePending = true
        source.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.chunkSize
        ) { [weak self] data, _, isComplete, error in
            guard let self, !self.cancelled else { return }
            self.receivePending = false
            if error != nil {
                self.onError()
                return
            }
            if let data, !data.isEmpty {
                self.enqueue(data)
            }
            if isComplete {
                self.sourceEnded = true
            }
            self.receiveNextChunk()
            self.finishIfReady()
        }
    }

    private func enqueue(_ data: Data) {
        bufferedBytes += data.count
        pendingSends += 1
        scheduler.schedule(byteCount: data.count) { [weak self] in
            guard let self, !self.cancelled else { return }
            if self.state.snapshot().offline {
                self.onError()
                return
            }
            self.destination.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.cancelled else { return }
                self.bufferedBytes -= data.count
                self.pendingSends -= 1
                if error != nil {
                    self.onError()
                    return
                }
                self.state.transferred(byteCount: data.count, direction: self.direction)
                self.receiveNextChunk()
                self.finishIfReady()
            })
        }
    }

    private func finishIfReady() {
        guard sourceEnded, pendingSends == 0, !cancelled else { return }
        cancelled = true
        destination.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [onComplete] _ in onComplete() }
        )
    }
}

private final class SOCKS5ByteReader {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func read(count: Int, completion: @escaping (Data?) -> Void) {
        read(count: count, accumulated: Data(), completion: completion)
    }

    private func read(
        count: Int,
        accumulated: Data,
        completion: @escaping (Data?) -> Void
    ) {
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

private final class NetworkShapingTunnel {
    enum Mode {
        case socks
        case direct(host: NWEndpoint.Host, port: NWEndpoint.Port)
    }

    private let identifier: UUID
    private let sequence: UInt64
    private let client: NWConnection
    private let queue: DispatchQueue
    private let state: NetworkShapingState
    private let mode: Mode
    private let onClose: (UUID) -> Void
    private lazy var reader = SOCKS5ByteReader(connection: client)
    private var upstream: NWConnection?
    private var uploadRelay: TrafficRelay?
    private var downloadRelay: TrafficRelay?
    private var completedRelays = 0
    private var finished = false

    init(
        identifier: UUID,
        sequence: UInt64,
        client: NWConnection,
        queue: DispatchQueue,
        state: NetworkShapingState,
        mode: Mode,
        onClose: @escaping (UUID) -> Void
    ) {
        self.identifier = identifier
        self.sequence = sequence
        self.client = client
        self.queue = queue
        self.state = state
        self.mode = mode
        self.onClose = onClose
    }

    func start() {
        client.stateUpdateHandler = { [weak self] connectionState in
            guard let self else { return }
            switch connectionState {
            case .ready:
                switch self.mode {
                case .socks:
                    self.readGreeting()
                case .direct(let host, let port):
                    self.connect(host: host, port: port)
                }
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        client.start(queue: queue)
    }

    func cancel() {
        finish()
    }

    private func readGreeting() {
        reader.read(count: 2) { [weak self] header in
            guard let self,
                  let header,
                  header.count == 2,
                  header[0] == 5 else {
                self?.finish()
                return
            }
            self.reader.read(count: Int(header[1])) { [weak self] methods in
                guard let self, let methods, methods.contains(0) else {
                    self?.send(Data([5, 0xFF])) { self?.finish() }
                    return
                }
                self.send(Data([5, 0])) { [weak self] in self?.readRequest() }
            }
        }
    }

    private func readRequest() {
        reader.read(count: 4) { [weak self] header in
            guard let self,
                  let header,
                  header.count == 4,
                  header[0] == 5,
                  header[1] == 1 else {
                self?.finish()
                return
            }
            self.readHost(addressType: header[3]) { [weak self] host in
                guard let self, let host else {
                    self?.sendReply(code: 8) { self?.finish() }
                    return
                }
                self.reader.read(count: 2) { [weak self] portBytes in
                    guard let self,
                          let portBytes,
                          portBytes.count == 2,
                          let port = NWEndpoint.Port(
                            rawValue: UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])
                          ) else {
                        self?.finish()
                        return
                    }
                    self.connect(host: NWEndpoint.Host(host), port: port)
                }
            }
        }
    }

    private func readHost(addressType: UInt8, completion: @escaping (String?) -> Void) {
        switch addressType {
        case 1:
            reader.read(count: 4) { data in
                completion(data.map { $0.map(String.init).joined(separator: ".") })
            }
        case 3:
            reader.read(count: 1) { [weak self] length in
                guard let self, let length, let count = length.first.map(Int.init) else {
                    completion(nil)
                    return
                }
                self.reader.read(count: count) { data in
                    completion(data.flatMap { String(data: $0, encoding: .utf8) })
                }
            }
        case 4:
            reader.read(count: 16) { data in
                completion(data.flatMap(Self.ipv6String))
            }
        default:
            completion(nil)
        }
    }

    private static func ipv6String(_ data: Data) -> String? {
        data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, address, &buffer, socklen_t(buffer.count)) != nil else {
                return nil
            }
            return String(cString: buffer)
        }
    }

    private func connect(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        guard !state.snapshot().offline else {
            finish()
            return
        }
        let upstream = NWConnection(host: host, port: port, using: .tcp)
        self.upstream = upstream
        upstream.stateUpdateHandler = { [weak self] connectionState in
            guard let self else { return }
            switch connectionState {
            case .ready: self.upstreamDidConnect(upstream)
            case .failed, .cancelled:
                if case .socks = self.mode {
                    self.sendReply(code: 5) { self.finish() }
                } else {
                    self.finish()
                }
            default: break
            }
        }
        upstream.start(queue: queue)
    }

    private func upstreamDidConnect(_ upstream: NWConnection) {
        let delay = state.snapshot().roundTripTimeMilliseconds / 1_000
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.finished, !self.state.snapshot().offline else {
                self?.finish()
                return
            }
            switch self.mode {
            case .socks:
                self.sendReply(code: 0) { [weak self] in
                    self?.startRelays(upstream: upstream)
                }
            case .direct:
                self.startRelays(upstream: upstream)
            }
        }
    }

    private func startRelays(upstream: NWConnection) {
        let configuration = state.snapshot()
        let tunnelSeed = configuration.seed &+ sequence &* 0x9E37_79B9_7F4A_7C15
        let failed: () -> Void = { [weak self] in self?.finish() }
        let completed: () -> Void = { [weak self] in self?.relayCompleted() }
        uploadRelay = TrafficRelay(
            source: client,
            destination: upstream,
            scheduler: TrafficScheduler(
                queue: queue,
                state: state,
                direction: .upload,
                seed: tunnelSeed ^ 0xA24B_AED4_963E_E407
            ),
            state: state,
            direction: .upload,
            onError: failed,
            onComplete: completed
        )
        downloadRelay = TrafficRelay(
            source: upstream,
            destination: client,
            scheduler: TrafficScheduler(
                queue: queue,
                state: state,
                direction: .download,
                seed: tunnelSeed ^ 0x9FB2_1C65_1E98_DF25
            ),
            state: state,
            direction: .download,
            onError: failed,
            onComplete: completed
        )
        uploadRelay?.start()
        downloadRelay?.start()
    }

    private func relayCompleted() {
        completedRelays += 1
        if completedRelays == 2 { finish() }
    }

    private func sendReply(code: UInt8, completion: @escaping () -> Void) {
        send(Data([5, code, 0, 1, 127, 0, 0, 1, 0, 0]), completion: completion)
    }

    private func send(_ data: Data, completion: @escaping () -> Void) {
        client.send(content: data, completion: .contentProcessed { error in
            if error == nil { completion() }
            else { self.finish() }
        })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        uploadRelay?.cancel()
        downloadRelay?.cancel()
        client.cancel()
        upstream?.cancel()
        onClose(identifier)
    }
}

final class NetworkShapingProxy {
    private static let localBridgeHost = "127.0.0.1"

    private let queue = DispatchQueue(label: "studio.viewdeck.network-shaping")
    private let state: NetworkShapingState
    private var listener: NWListener?
    private var localBridgeListener: NWListener?
    private var localBridgeTargetHost: String?
    private var localBridgeTargetPort: NWEndpoint.Port?
    private var localBridgePort: NWEndpoint.Port?
    private var tunnels: [UUID: NetworkShapingTunnel] = [:]
    private var nextTunnelSequence: UInt64 = 0
    private(set) var port: NWEndpoint.Port?

    init(configuration: NetworkShapingConfiguration) {
        state = NetworkShapingState(configuration: configuration)
    }

    @discardableResult
    func start(timeout: TimeInterval = 2) throws -> NWEndpoint.Port {
        if let port { return port }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let (listener, port) = try startListener(
            parameters: parameters,
            timeout: timeout,
            failure: { NetworkShapingError.listenerFailed($0) },
            onConnection: { [weak self] connection in self?.accept(connection) }
        )
        self.listener = listener
        self.port = port
        return port
    }

    func shapedURL(for url: URL, timeout: TimeInterval = 2) throws -> URL {
        guard state.snapshot().enabled,
              url.scheme?.lowercased() == "http",
              let host = url.host,
              Self.isLoopbackHost(host) else { return url }

        let portValue = url.port ?? 80
        guard let rawPort = UInt16(exactly: portValue),
              let targetPort = NWEndpoint.Port(rawValue: rawPort) else {
            throw NetworkShapingError.localBridgeRequiresPort
        }
        if localBridgeTargetHost != host || localBridgeTargetPort != targetPort {
            try startLocalBridge(targetHost: host, port: targetPort, timeout: timeout)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.host = Self.localBridgeHost
        components.port = localBridgePort.map { Int($0.rawValue) }
        return components.url ?? url
    }

    func update(configuration: NetworkShapingConfiguration) {
        state.update(configuration)
        guard configuration.offline else { return }
        queue.async { [weak self] in
            self?.tunnels.values.forEach { $0.cancel() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.localBridgeListener?.cancel()
            self.localBridgeListener = nil
            self.tunnels.values.forEach { $0.cancel() }
            self.tunnels.removeAll()
        }
    }

    func report(configuration: NetworkShapingConfiguration) -> [String: Any] {
        let statistics = state.statisticsSnapshot()
        var report = configuration.reportDictionary
        report["implementation"] = configuration.enabled
            ? (localBridgeListener == nil ? "loopbackSOCKSv5Proxy" : "loopbackTCPBridge+SOCKSv5Proxy")
            : "none"
        report["proxyPort"] = port?.rawValue ?? 0
        report["localBridgeHost"] = localBridgeListener == nil ? NSNull() : Self.localBridgeHost
        report["localBridgePort"] = localBridgePort?.rawValue ?? 0
        report["localBridgeTargetHost"] = localBridgeTargetHost ?? NSNull()
        report["localBridgeTargetPort"] = localBridgeTargetPort?.rawValue ?? 0
        report["acceptedConnectionCount"] = statistics.acceptedConnections
        report["activeConnectionCount"] = statistics.activeConnections
        report["uploadedBytes"] = statistics.uploadedBytes
        report["downloadedBytes"] = statistics.downloadedBytes
        report["trafficObserved"] = statistics.acceptedConnections > 0
            && statistics.uploadedBytes + statistics.downloadedBytes > 0
        report["transportScope"] = "TCP traffic from the primary WKWebView"
        report["http3QUICShaped"] = false
        return report
    }

    private func startLocalBridge(
        targetHost: String,
        port: NWEndpoint.Port,
        timeout: TimeInterval
    ) throws {
        localBridgeListener?.cancel()
        localBridgeListener = nil
        localBridgeTargetHost = nil
        localBridgeTargetPort = nil
        localBridgePort = nil

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(Self.localBridgeHost),
            port: .any
        )
        let targetEndpoint = NetworkShapingTunnel.Mode.direct(
            host: NWEndpoint.Host(targetHost),
            port: port
        )
        let (bridge, bridgePort) = try startListener(
            parameters: parameters,
            timeout: timeout,
            failure: {
                NetworkShapingError.localBridgeUnavailable(Int(port.rawValue), $0)
            },
            onConnection: { [weak self] connection in
                self?.accept(connection, mode: targetEndpoint)
            }
        )
        localBridgeListener = bridge
        localBridgePort = bridgePort
        localBridgeTargetHost = targetHost
        localBridgeTargetPort = port
    }

    private func startListener(
        parameters: NWParameters,
        timeout: TimeInterval,
        failure: @escaping (String) -> Error,
        onConnection: @escaping (NWConnection) -> Void
    ) throws -> (listener: NWListener, port: NWEndpoint.Port) {
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw failure(error.localizedDescription)
        }
        listener.newConnectionHandler = onConnection

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<NWEndpoint.Port, Error>?
        listener.stateUpdateHandler = { state in
            guard result == nil else { return }
            switch state {
            case .ready:
                result = listener.port.map(Result.success)
                    ?? .failure(NetworkShapingError.listenerHasNoPort)
                semaphore.signal()
            case .failed(let error):
                result = .failure(failure(error.localizedDescription))
                semaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            listener.cancel()
            throw NetworkShapingError.listenerTimedOut
        }
        guard let result else { throw NetworkShapingError.listenerHasNoPort }
        return (listener, try result.get())
    }

    private static func isLoopbackHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: "[]")
        )
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "::1"
            || host == "0.0.0.0"
            || host.hasPrefix("127.")
    }

    private func accept(
        _ connection: NWConnection,
        mode: NetworkShapingTunnel.Mode = .socks
    ) {
        nextTunnelSequence &+= 1
        let identifier = UUID()
        let tunnel = NetworkShapingTunnel(
            identifier: identifier,
            sequence: nextTunnelSequence,
            client: connection,
            queue: queue,
            state: state,
            mode: mode,
            onClose: { [weak self] identifier in
                self?.tunnelDidClose(identifier)
            }
        )
        tunnels[identifier] = tunnel
        state.connectionOpened()
        tunnel.start()
    }

    private func tunnelDidClose(_ identifier: UUID) {
        guard tunnels.removeValue(forKey: identifier) != nil else { return }
        state.connectionClosed()
    }
}
