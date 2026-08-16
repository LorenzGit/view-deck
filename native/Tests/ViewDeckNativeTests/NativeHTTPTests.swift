import AppKit
import Network
import WebKit
import XCTest
@testable import ViewDeckCore

private func nativeHTTPWebView(in view: NSView) -> WKWebView? {
    if let webView = view as? WKWebView { return webView }
    return view.subviews.lazy.compactMap(nativeHTTPWebView).first
}

private final class NativeHTTPNavigationProbe: DevicePreviewDelegate {
    var didFinish: ((URL?) -> Void)?
    var didFail: ((String) -> Void)?

    func previewDidStartLoading() {}
    func previewDidFinishLoading(title: String?, url: URL?) { didFinish?(url) }
    func previewDidFail(_ message: String) { didFail?(message) }
}

final class NativeHTTPTests: XCTestCase {
    func testOrdinaryFetchFailsCORSWhileEnabledNativeBridgeSucceeds() throws {
        let server = try NativeHTTPFixtureServer()
        defer { server.stop() }
        let completed = expectation(description: "CORS fails and native HTTP succeeds")
        var retained: (DevicePreviewView, NativeHTTPNavigationProbe)?

        DispatchQueue.main.async {
            let preview = DevicePreviewView(
                profile: BuiltinDevices.all[1],
                nativeHTTPConfiguration: NativeHTTPConfiguration(
                    enabled: true,
                    allowedHosts: ["127.0.0.1"]
                )
            )
            let probe = NativeHTTPNavigationProbe()
            retained = (preview, probe)
            preview.delegate = probe
            probe.didFinish = { url in
                guard url?.host == "localhost", let webView = nativeHTTPWebView(in: preview) else { return }
                webView.callAsyncJavaScript(
                    """
                    let ordinaryFetchFailed = false;
                    try {
                      await fetch('http://127.0.0.1:\(server.port.rawValue)/cors');
                    } catch (_) {
                      ordinaryFetchFailed = true;
                    }
                    const response = await window.viewdeck.nativeHttp.request({
                      url: 'http://127.0.0.1:\(server.port.rawValue)/cors',
                      method: 'GET',
                      responseType: 'json'
                    });
                    return JSON.stringify({
                      ordinaryFetchFailed,
                      status: response.status,
                      data: response.data,
                      enabled: window.viewdeck.nativeHttp.enabled
                    });
                    """,
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { result in
                    do {
                        let encoded = try result.get() as? String
                        let data = try XCTUnwrap(encoded?.data(using: .utf8))
                        let value = try XCTUnwrap(
                            JSONSerialization.jsonObject(with: data) as? [String: Any]
                        )
                        XCTAssertEqual(value["ordinaryFetchFailed"] as? Bool, true)
                        XCTAssertEqual(value["status"] as? Int, 200)
                        XCTAssertEqual((value["data"] as? [String: Any])?["native"] as? String, "ok")
                        XCTAssertEqual(value["enabled"] as? Bool, true)
                        XCTAssertEqual(server.requestCount(path: "/cors"), 2)
                    } catch {
                        XCTFail("Could not inspect the native HTTP result: \(error)")
                    }
                    completed.fulfill()
                }
            }
            probe.didFail = { message in
                XCTFail("Preview failed: \(message)")
                completed.fulfill()
            }
            preview.load("http://localhost:\(server.port.rawValue)/page")
        }

        wait(for: [completed], timeout: 8)
        withExtendedLifetime(retained) {}
    }

    func testDisabledBridgeRejectsBeforeNetworkAccess() throws {
        let server = try NativeHTTPFixtureServer()
        defer { server.stop() }
        try assertRejectedBeforeNetwork(
            server: server,
            configuration: .disabled,
            path: "/disabled",
            expectedCode: "disabled"
        )
    }

    func testNonAllowlistedHostRejectsBeforeNetworkAccess() throws {
        let server = try NativeHTTPFixtureServer()
        defer { server.stop() }
        try assertRejectedBeforeNetwork(
            server: server,
            configuration: NativeHTTPConfiguration(enabled: true, allowedHosts: ["localhost"]),
            path: "/blocked",
            expectedCode: "host-not-allowlisted"
        )
    }

    func testRedirectCannotEscapeAllowlist() throws {
        let server = try NativeHTTPFixtureServer()
        defer { server.stop() }
        let completed = expectation(description: "Redirect escape is blocked")
        var retained: (DevicePreviewView, NativeHTTPNavigationProbe)?

        DispatchQueue.main.async {
            let preview = DevicePreviewView(
                profile: BuiltinDevices.all[1],
                nativeHTTPConfiguration: NativeHTTPConfiguration(
                    enabled: true,
                    allowedHosts: ["127.0.0.1"]
                )
            )
            let probe = NativeHTTPNavigationProbe()
            retained = (preview, probe)
            preview.delegate = probe
            probe.didFinish = { url in
                guard url?.host == "localhost", let webView = nativeHTTPWebView(in: preview) else { return }
                webView.callAsyncJavaScript(
                    """
                    try {
                      await window.viewdeck.nativeHttp.request({
                        url: 'http://127.0.0.1:\(server.port.rawValue)/redirect',
                        method: 'GET'
                      });
                      return JSON.stringify({ rejected: false });
                    } catch (error) {
                      return JSON.stringify({ rejected: true, code: error.code });
                    }
                    """,
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { result in
                    do {
                        let encoded = try result.get() as? String
                        let data = try XCTUnwrap(encoded?.data(using: .utf8))
                        let value = try XCTUnwrap(
                            JSONSerialization.jsonObject(with: data) as? [String: Any]
                        )
                        XCTAssertEqual(value["rejected"] as? Bool, true)
                        XCTAssertEqual(value["code"] as? String, "redirect-not-allowlisted")
                        XCTAssertEqual(server.requestCount(path: "/redirect"), 1)
                        XCTAssertEqual(server.requestCount(path: "/escaped"), 0)
                        let report = preview.nativeHTTPReport()
                        XCTAssertEqual(report["failureCount"] as? Int, 1)
                        XCTAssertEqual(
                            (report["requests"] as? [[String: Any]])?.first?["status"] as? Int,
                            302
                        )
                    } catch {
                        XCTFail("Could not inspect the redirect result: \(error)")
                    }
                    completed.fulfill()
                }
            }
            probe.didFail = { message in
                XCTFail("Preview failed: \(message)")
                completed.fulfill()
            }
            preview.load("http://localhost:\(server.port.rawValue)/page")
        }

        wait(for: [completed], timeout: 8)
        withExtendedLifetime(retained) {}
    }

    func testMethodsHeadersBodiesStatusesResponsesAndReportsRemainExactAndRedacted() throws {
        let server = try NativeHTTPFixtureServer()
        defer { server.stop() }
        let completed = expectation(description: "Request fidelity and redaction are verified")
        let utf8Body = "{\"emoji\":\"🦊\",\"line\":\"a\\nb\"}"
        let authorization = "Bearer top-secret-token"
        let cookie = "session=private-cookie"
        var retained: (DevicePreviewView, NativeHTTPNavigationProbe)?

        DispatchQueue.main.async {
            let preview = DevicePreviewView(
                profile: BuiltinDevices.all[1],
                nativeHTTPConfiguration: NativeHTTPConfiguration(
                    enabled: true,
                    allowedHosts: ["127.0.0.1"]
                )
            )
            let probe = NativeHTTPNavigationProbe()
            retained = (preview, probe)
            preview.delegate = probe
            probe.didFinish = { url in
                guard url?.host == "localhost", let webView = nativeHTTPWebView(in: preview) else { return }
                webView.callAsyncJavaScript(
                    """
                    const response = await window.viewdeck.nativeHttp.request({
                      url: 'http://127.0.0.1:\(server.port.rawValue)/echo?token=sensitive-query-value',
                      method: 'PATCH',
                      headers: {
                        'Authorization': '\(authorization)',
                        'Cookie': '\(cookie)',
                        'X-Exact': 'Case-Sensitive-Value'
                      },
                      body: \(javaScriptString(utf8Body)),
                      responseType: 'json'
                    });
                    const binary = await window.viewdeck.nativeHttp.request({
                      url: 'http://127.0.0.1:\(server.port.rawValue)/binary',
                      method: 'GET',
                      responseType: 'binary'
                    });
                    const responseHeader = Object.entries(response.headers)
                      .find(([name]) => name.toLowerCase() === 'x-bridge-response')?.[1];
                    return JSON.stringify({
                      status: response.status,
                      responseHeader,
                      echoed: response.data,
                      binary: Array.from(new Uint8Array(binary.data))
                    });
                    """,
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { result in
                    do {
                        let encoded = try result.get() as? String
                        let data = try XCTUnwrap(encoded?.data(using: .utf8))
                        let value = try XCTUnwrap(
                            JSONSerialization.jsonObject(with: data) as? [String: Any]
                        )
                        let echoed = try XCTUnwrap(value["echoed"] as? [String: Any])
                        XCTAssertEqual(value["status"] as? Int, 207)
                        XCTAssertEqual(value["responseHeader"] as? String, "exact")
                        XCTAssertEqual(echoed["method"] as? String, "PATCH")
                        XCTAssertEqual(echoed["body"] as? String, utf8Body)
                        XCTAssertEqual(echoed["authorization"] as? String, authorization)
                        XCTAssertEqual(echoed["cookie"] as? String, cookie)
                        XCTAssertEqual(echoed["exact"] as? String, "Case-Sensitive-Value")
                        XCTAssertEqual(value["binary"] as? [Int], [0, 1, 2, 255])

                        preview.captureAudit { auditResult in
                            do {
                                let audit = try auditResult.get()
                                let reportData = try JSONSerialization.data(withJSONObject: [
                                    "nativeHttp": preview.nativeHTTPReport(),
                                    "audit": audit
                                ], options: [.sortedKeys])
                                let report = try XCTUnwrap(String(data: reportData, encoding: .utf8))
                                for sensitive in [
                                    authorization, cookie, "sensitive-query-value", "Authorization",
                                    "Cookie", "X-Exact"
                                ] {
                                    XCTAssertFalse(report.contains(sensitive))
                                }
                                let nativeReport = preview.nativeHTTPReport()
                                XCTAssertEqual(nativeReport["requestCount"] as? Int, 2)
                                XCTAssertEqual(nativeReport["successCount"] as? Int, 2)
                                XCTAssertEqual(nativeReport["failureCount"] as? Int, 0)
                                let requests = nativeReport["requests"] as? [[String: Any]]
                                XCTAssertEqual(requests?.map { $0["host"] as? String }, [
                                    "127.0.0.1", "127.0.0.1"
                                ])
                                XCTAssertEqual(requests?.map { $0["status"] as? Int }, [207, 200])
                            } catch {
                                XCTFail("Could not inspect the redacted report: \(error)")
                            }
                            completed.fulfill()
                        }
                    } catch {
                        XCTFail("Could not inspect request fidelity: \(error)")
                        completed.fulfill()
                    }
                }
            }
            probe.didFail = { message in
                XCTFail("Preview failed: \(message)")
                completed.fulfill()
            }
            preview.load("http://localhost:\(server.port.rawValue)/page")
        }

        wait(for: [completed], timeout: 8)
        withExtendedLifetime(retained) {}
    }

    private func assertRejectedBeforeNetwork(
        server: NativeHTTPFixtureServer,
        configuration: NativeHTTPConfiguration,
        path: String,
        expectedCode: String
    ) throws {
        let completed = expectation(description: "Native HTTP rejects before network access")
        var retained: (DevicePreviewView, NativeHTTPNavigationProbe)?

        DispatchQueue.main.async {
            let preview = DevicePreviewView(
                profile: BuiltinDevices.all[1],
                nativeHTTPConfiguration: configuration
            )
            let probe = NativeHTTPNavigationProbe()
            retained = (preview, probe)
            preview.delegate = probe
            probe.didFinish = { url in
                guard url?.host == "localhost", let webView = nativeHTTPWebView(in: preview) else { return }
                webView.callAsyncJavaScript(
                    """
                    try {
                      await window.viewdeck.nativeHttp.request({
                        url: 'http://127.0.0.1:\(server.port.rawValue)\(path)',
                        method: 'GET'
                      });
                      return JSON.stringify({ rejected: false });
                    } catch (error) {
                      return JSON.stringify({ rejected: true, code: error.code });
                    }
                    """,
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { result in
                    do {
                        let encoded = try result.get() as? String
                        let data = try XCTUnwrap(encoded?.data(using: .utf8))
                        let value = try XCTUnwrap(
                            JSONSerialization.jsonObject(with: data) as? [String: Any]
                        )
                        XCTAssertEqual(value["rejected"] as? Bool, true)
                        XCTAssertEqual(value["code"] as? String, expectedCode)
                        XCTAssertEqual(server.requestCount(path: path), 0)
                        let report = preview.nativeHTTPReport()
                        XCTAssertEqual(report["requestCount"] as? Int, 1)
                        XCTAssertEqual(report["failureCount"] as? Int, 1)
                    } catch {
                        XCTFail("Could not inspect the rejection result: \(error)")
                    }
                    completed.fulfill()
                }
            }
            probe.didFail = { message in
                XCTFail("Preview failed: \(message)")
                completed.fulfill()
            }
            preview.load("http://localhost:\(server.port.rawValue)/page")
        }

        wait(for: [completed], timeout: 8)
        withExtendedLifetime(retained) {}
    }
}

private func javaScriptString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let array = String(data: data, encoding: .utf8) else { return "\"\"" }
    return String(array.dropFirst().dropLast())
}

private final class NativeHTTPFixtureServer {
    private let queue = DispatchQueue(label: "studio.viewdeck.tests.native-http-server")
    private let listener: NWListener
    private let lock = NSLock()
    private var requestCounts: [String: Int] = [:]
    private(set) var port: NWEndpoint.Port!

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        var readyPort: NWEndpoint.Port?
        listener.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            readyPort = listener.port
            ready.signal()
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, accumulated: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, let readyPort else {
            throw NSError(domain: "NativeHTTPFixtureServer", code: 1)
        }
        port = readyPort
    }

    func stop() {
        listener.cancel()
    }

    func requestCount(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[path] ?? 0
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var request = accumulated
            if let data { request.append(data) }
            if let parsed = self.parse(request) {
                self.respond(to: parsed, on: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receive(on: connection, accumulated: request)
            }
        }
    }

    private func parse(_ data: Data) -> NativeHTTPFixtureRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", maxSplits: 2).map(String.init) ?? []
        guard requestLine.count == 3 else { return nil }
        let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
            guard let colon = line.firstIndex(of: ":") else { return }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return NativeHTTPFixtureRequest(
            method: requestLine[0],
            target: requestLine[1],
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + contentLength)])
        )
    }

    private func respond(to request: NativeHTTPFixtureRequest, on connection: NWConnection) {
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
        lock.lock()
        requestCounts[path, default: 0] += 1
        lock.unlock()

        let status: String
        let headers: [String]
        let body: Data
        switch path {
        case "/page":
            status = "200 OK"
            headers = ["Content-Type: text/html; charset=utf-8"]
            body = Data("<!doctype html><title>native HTTP fixture</title>".utf8)
        case "/cors":
            status = "200 OK"
            headers = ["Content-Type: application/json"]
            body = Data("{\"native\":\"ok\"}".utf8)
        case "/echo":
            status = "207 Multi-Status"
            headers = ["Content-Type: application/json", "X-Bridge-Response: exact"]
            let value: [String: Any] = [
                "method": request.method,
                "target": request.target,
                "body": String(data: request.body, encoding: .utf8) ?? "",
                "authorization": request.headers["authorization"] ?? "",
                "cookie": request.headers["cookie"] ?? "",
                "exact": request.headers["x-exact"] ?? ""
            ]
            body = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        case "/binary":
            status = "200 OK"
            headers = ["Content-Type: application/octet-stream"]
            body = Data([0, 1, 2, 255])
        case "/redirect":
            status = "302 Found"
            headers = ["Location: http://localhost:\(port.rawValue)/escaped"]
            body = Data()
        case "/escaped", "/blocked", "/disabled":
            status = "200 OK"
            headers = ["Content-Type: text/plain"]
            body = Data("network access occurred".utf8)
        default:
            status = "404 Not Found"
            headers = ["Content-Type: text/plain"]
            body = Data("missing".utf8)
        }

        let head = ([
            "HTTP/1.1 \(status)",
            "Content-Length: \(body.count)",
            "Connection: close"
        ] + headers + ["", ""]).joined(separator: "\r\n")
        var response = Data(head.utf8)
        response.append(body)
        connection.send(
            content: response,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}

private struct NativeHTTPFixtureRequest {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data
}
