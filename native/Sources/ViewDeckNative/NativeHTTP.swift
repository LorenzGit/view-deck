import Foundation
import Network
import WebKit

struct NativeHTTPConfiguration: Codable, Equatable {
    var enabled: Bool
    var allowedHosts: [String]

    static let disabled = NativeHTTPConfiguration(enabled: false, allowedHosts: [])

    var normalized: NativeHTTPConfiguration {
        var seen = Set<String>()
        let hosts = allowedHosts.compactMap(Self.normalizedHost).filter { seen.insert($0).inserted }
        return NativeHTTPConfiguration(enabled: enabled, allowedHosts: hosts)
    }

    func allows(_ host: String) -> Bool {
        guard let normalizedHost = Self.normalizedHost(host) else { return false }
        return normalized.allowedHosts.contains(normalizedHost)
    }

    static func normalizedHost(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains(where: { $0.isWhitespace }),
              !value.contains("/"),
              !value.contains("?"),
              !value.contains("#"),
              !value.contains("@"),
              !value.contains("*") else { return nil }

        let candidate: String
        if value.hasPrefix("[") && value.hasSuffix("]") {
            let address = String(value.dropFirst().dropLast())
            guard IPv6Address(address) != nil else { return nil }
            candidate = value
        } else if value.contains(":") {
            guard IPv6Address(value) != nil else { return nil }
            candidate = "[\(value)]"
        } else {
            candidate = value
        }
        guard let components = URLComponents(string: "https://\(candidate)"),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }
}

private struct NativeHTTPReportEntry {
    var host: String
    var status: Int
    var outcome: String

    var dictionary: [String: Any] {
        [
            "host": host,
            "status": status,
            "outcome": outcome
        ]
    }
}

private final class NativeHTTPPendingRequest {
    let id: String
    let host: String
    let responseType: String
    let generation: Int
    let reportIndex: Int
    let reply: (Any?, String?) -> Void
    var data = Data()
    var response: HTTPURLResponse?
    var failureCode: String?
    var failureStatus = 0
    weak var task: URLSessionTask?

    init(
        id: String,
        host: String,
        responseType: String,
        generation: Int,
        reportIndex: Int,
        reply: @escaping (Any?, String?) -> Void
    ) {
        self.id = id
        self.host = host
        self.responseType = responseType
        self.generation = generation
        self.reportIndex = reportIndex
        self.reply = reply
    }
}

final class NativeHTTPBridge: NSObject, WKScriptMessageHandlerWithReply, URLSessionDataDelegate {
    static let messageHandlerName = "viewdeckNativeHttp"
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 60

    private(set) var configuration: NativeHTTPConfiguration
    private var session: URLSession!
    private var pendingByTaskIdentifier: [Int: NativeHTTPPendingRequest] = [:]
    private var taskIdentifierByRequestID: [String: Int] = [:]
    private var reportEntries: [NativeHTTPReportEntry] = []
    private var generation = 0
    private var isShutDown = false

    init(configuration: NativeHTTPConfiguration) {
        self.configuration = configuration.normalized
        super.init()
        makeSession()
    }

    func update(configuration: NativeHTTPConfiguration) {
        self.configuration = configuration.normalized
        resetForCleanSiteRun()
    }

    func resetForCleanSiteRun() {
        generation &+= 1
        reportEntries = []
        replaceSession()
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        session?.invalidateAndCancel()
        session = nil
        pendingByTaskIdentifier = [:]
        taskIdentifierByRequestID = [:]
    }

    func report() -> [String: Any] {
        let successes = reportEntries.filter { $0.outcome == "success" }.count
        let failures = reportEntries.filter { $0.outcome == "failure" }.count
        return [
            "enabled": configuration.enabled,
            "state": configuration.enabled ? "enabled" : "disabled",
            "allowlistedHosts": configuration.allowedHosts,
            "requestCount": reportEntries.count,
            "successCount": successes,
            "failureCount": failures,
            "requests": reportEntries.map(\.dictionary),
            "transport": "nativeURLSession",
            "cookiesPersisted": false,
            "credentialsPersisted": false
        ]
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            replyHandler(Self.failure(code: "invalid-request", message: "Invalid native HTTP request."), nil)
            return
        }
        switch action {
        case "request":
            startRequest(body, reply: replyHandler)
        case "cancel":
            cancelRequest(body["id"] as? String)
            replyHandler(["ok": true], nil)
        default:
            replyHandler(Self.failure(code: "invalid-action", message: "Unknown native HTTP action."), nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        pendingByTaskIdentifier[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pendingByTaskIdentifier[dataTask.taskIdentifier]?.data.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard pendingByTaskIdentifier[task.taskIdentifier] != nil,
              let url = request.url,
              Self.isSupportedURL(url),
              url.user == nil,
              url.password == nil,
              let host = url.host,
              configuration.allows(host) else {
            if let pending = pendingByTaskIdentifier[task.taskIdentifier] {
                pending.failureCode = "redirect-not-allowlisted"
                pending.failureStatus = response.statusCode
            }
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let pending = pendingByTaskIdentifier.removeValue(forKey: task.taskIdentifier) else {
            return
        }
        taskIdentifierByRequestID[pending.id] = nil

        if let failureCode = pending.failureCode {
            finish(
                pending,
                status: pending.failureStatus,
                response: Self.failure(
                    code: failureCode,
                    message: failureCode == "redirect-not-allowlisted"
                        ? "The redirect target host is not allowlisted."
                        : "The native HTTP request was cancelled."
                )
            )
            return
        }
        if let error {
            let code: String
            let message: String
            switch (error as? URLError)?.code {
            case .timedOut:
                code = "timeout"
                message = "The native HTTP request timed out."
            case .cancelled:
                code = "cancelled"
                message = "The native HTTP request was cancelled."
            default:
                code = "network-error"
                message = "The native HTTP request failed."
            }
            finish(pending, status: pending.response?.statusCode ?? 0, response: Self.failure(
                code: code,
                message: message
            ))
            return
        }
        guard let response = pending.response else {
            finish(pending, status: 0, response: Self.failure(
                code: "invalid-response",
                message: "The native HTTP response was invalid."
            ))
            return
        }

        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let name = pair.key as? String else { return }
            result[name] = String(describing: pair.value)
        }
        finish(pending, status: response.statusCode, response: [
            "ok": true,
            "status": response.statusCode,
            "headers": headers,
            "responseType": pending.responseType,
            "bodyBase64": pending.data.base64EncodedString()
        ])
    }

    var bootstrapScript: String {
        """
        (() => {
          const root = window.viewdeck && typeof window.viewdeck === 'object'
            ? window.viewdeck
            : (window.viewdeck = {});
          const handler = window.webkit?.messageHandlers?.\(Self.messageHandlerName);
          const decodeBytes = value => {
            const binary = atob(value || '');
            const bytes = new Uint8Array(binary.length);
            for (let index = 0; index < binary.length; index += 1) {
              bytes[index] = binary.charCodeAt(index);
            }
            return bytes;
          };
          const encodeBytes = bytes => {
            let binary = '';
            const chunkSize = 0x8000;
            for (let index = 0; index < bytes.length; index += chunkSize) {
              binary += String.fromCharCode(...bytes.subarray(index, index + chunkSize));
            }
            return btoa(binary);
          };
          const abortError = () => new DOMException('The native HTTP request was cancelled.', 'AbortError');
          const request = async options => {
            if (!options || typeof options !== 'object') {
              throw new TypeError('nativeHttp.request requires an options object.');
            }
            const responseType = options.responseType || 'text';
            if (!['text', 'json', 'binary', 'arraybuffer', 'base64'].includes(responseType)) {
              throw new TypeError('Unsupported native HTTP responseType.');
            }
            if (options.signal && typeof options.signal.addEventListener !== 'function') {
              throw new TypeError('nativeHttp.request signal must be an AbortSignal.');
            }
            const headers = {};
            for (const [name, value] of Object.entries(options.headers || {})) {
              if (typeof value !== 'string') throw new TypeError('Native HTTP header values must be strings.');
              headers[name] = value;
            }
            let body = null;
            if (typeof options.body === 'string') {
              body = { encoding: 'utf8', value: options.body };
            } else if (options.body instanceof ArrayBuffer) {
              body = { encoding: 'base64', value: encodeBytes(new Uint8Array(options.body)) };
            } else if (ArrayBuffer.isView(options.body)) {
              body = {
                encoding: 'base64',
                value: encodeBytes(new Uint8Array(
                  options.body.buffer,
                  options.body.byteOffset,
                  options.body.byteLength
                ))
              };
            } else if (options.body !== undefined && options.body !== null) {
              body = { encoding: 'utf8', value: JSON.stringify(options.body) };
            }
            const id = globalThis.crypto?.randomUUID?.()
              || `viewdeck-${Date.now()}-${Math.random().toString(16).slice(2)}`;
            if (options.signal?.aborted) throw abortError();
            const nativePromise = handler.postMessage({
              action: 'request',
              id,
              request: {
                url: options.url,
                method: options.method || 'GET',
                headers,
                body,
                responseType,
                timeoutMilliseconds: options.timeoutMilliseconds
              }
            });
            let abortListener;
            const abortPromise = options.signal && new Promise((_, reject) => {
              abortListener = () => {
                handler.postMessage({ action: 'cancel', id }).catch(() => {});
                reject(abortError());
              };
              options.signal.addEventListener('abort', abortListener, { once: true });
            });
            let reply;
            try {
              reply = await (abortPromise ? Promise.race([nativePromise, abortPromise]) : nativePromise);
            } finally {
              if (abortListener) options.signal.removeEventListener('abort', abortListener);
            }
            if (!reply?.ok) {
              const error = new Error(reply?.error?.message || 'Native HTTP request failed.');
              error.code = reply?.error?.code || 'native-http-error';
              throw error;
            }
            const bytes = decodeBytes(reply.bodyBase64);
            let data;
            if (responseType === 'binary' || responseType === 'arraybuffer') {
              data = bytes.buffer;
            } else if (responseType === 'base64') {
              data = reply.bodyBase64;
            } else {
              const text = new TextDecoder('utf-8').decode(bytes);
              data = responseType === 'json' ? (text.length ? JSON.parse(text) : null) : text;
            }
            return {
              status: reply.status,
              headers: reply.headers || {},
              data,
              responseType
            };
          };
          root.nativeHttp = Object.freeze({
            enabled: \(configuration.enabled ? "true" : "false"),
            allowedHosts: Object.freeze(\(Self.javaScriptArray(configuration.allowedHosts))),
            request
          });
        })();
        """
    }

    private func startRequest(_ body: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        let requestID = body["id"] as? String ?? UUID().uuidString
        let values = body["request"] as? [String: Any] ?? [:]
        let rawURL = values["url"] as? String ?? ""
        let requestedHost = URLComponents(string: rawURL)?.host
            .flatMap(NativeHTTPConfiguration.normalizedHost) ?? ""

        guard configuration.enabled else {
            rejectBeforeNetwork(
                host: requestedHost,
                code: "disabled",
                message: "Native HTTP is disabled for this ViewDeck run.",
                reply: reply
            )
            return
        }
        guard let url = URL(string: rawURL),
              Self.isSupportedURL(url),
              url.user == nil,
              url.password == nil,
              let host = url.host.flatMap(NativeHTTPConfiguration.normalizedHost) else {
            rejectBeforeNetwork(
                host: requestedHost,
                code: "invalid-url",
                message: "Native HTTP requires an HTTP or HTTPS URL without embedded credentials.",
                reply: reply
            )
            return
        }
        guard configuration.allows(host) else {
            rejectBeforeNetwork(
                host: host,
                code: "host-not-allowlisted",
                message: "The requested host is not allowlisted.",
                reply: reply
            )
            return
        }
        guard let request = Self.urlRequest(url: url, values: values) else {
            rejectBeforeNetwork(
                host: host,
                code: "invalid-request",
                message: "The native HTTP request options are invalid.",
                reply: reply
            )
            return
        }

        let responseType = values["responseType"] as? String ?? "text"
        let task = session.dataTask(with: request)
        let reportIndex = appendReportEntry(host: host, status: 0, outcome: "pending")
        let pending = NativeHTTPPendingRequest(
            id: requestID,
            host: host,
            responseType: responseType,
            generation: generation,
            reportIndex: reportIndex,
            reply: reply
        )
        pendingByTaskIdentifier[task.taskIdentifier] = pending
        taskIdentifierByRequestID[requestID] = task.taskIdentifier
        pending.task = task
        task.resume()
    }

    private func cancelRequest(_ requestID: String?) {
        guard let requestID,
              let taskIdentifier = taskIdentifierByRequestID[requestID],
              let pending = pendingByTaskIdentifier[taskIdentifier],
              let task = pending.task else { return }
        pending.failureCode = "cancelled"
        task.cancel()
    }

    private func rejectBeforeNetwork(
        host: String,
        code: String,
        message: String,
        reply: (Any?, String?) -> Void
    ) {
        _ = appendReportEntry(host: host, status: 0, outcome: "failure")
        reply(Self.failure(code: code, message: message), nil)
    }

    private func finish(
        _ pending: NativeHTTPPendingRequest,
        status: Int,
        response: [String: Any]
    ) {
        updateReportEntry(
            at: pending.reportIndex,
            status: status,
            outcome: response["ok"] as? Bool == true ? "success" : "failure",
            generation: pending.generation
        )
        pending.reply(response, nil)
    }

    private func appendReportEntry(host: String, status: Int, outcome: String) -> Int {
        reportEntries.append(NativeHTTPReportEntry(
            host: host.isEmpty ? "invalid" : host,
            status: status,
            outcome: outcome
        ))
        return reportEntries.count - 1
    }

    private func updateReportEntry(
        at index: Int,
        status: Int,
        outcome: String,
        generation: Int
    ) {
        guard generation == self.generation, reportEntries.indices.contains(index) else { return }
        reportEntries[index].status = status
        reportEntries[index].outcome = outcome
    }

    private func replaceSession() {
        session?.invalidateAndCancel()
        pendingByTaskIdentifier = [:]
        taskIdentifierByRequestID = [:]
        guard !isShutDown else { return }
        makeSession()
    }

    private func makeSession() {
        let value = URLSessionConfiguration.ephemeral
        value.requestCachePolicy = .reloadIgnoringLocalCacheData
        value.urlCache = nil
        value.httpCookieStorage = nil
        value.httpShouldSetCookies = false
        value.urlCredentialStorage = nil
        value.timeoutIntervalForRequest = Self.requestTimeout
        value.timeoutIntervalForResource = Self.resourceTimeout
        session = URLSession(configuration: value, delegate: self, delegateQueue: .main)
    }

    private static func urlRequest(url: URL, values: [String: Any]) -> URLRequest? {
        guard let method = values["method"] as? String,
              !method.isEmpty,
              let rawHeaders = values["headers"] as? [String: Any] else { return nil }
        var headers: [String: String] = [:]
        for (name, value) in rawHeaders {
            guard let value = value as? String else { return nil }
            headers[name] = value
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.allHTTPHeaderFields = headers
        if let timeout = values["timeoutMilliseconds"] as? NSNumber,
           timeout.doubleValue.isFinite,
           timeout.doubleValue > 0 {
            request.timeoutInterval = min(
                resourceTimeout,
                max(0.1, timeout.doubleValue / 1_000)
            )
        } else {
            request.timeoutInterval = requestTimeout
        }
        if let body = values["body"] as? [String: Any] {
            guard let encoding = body["encoding"] as? String,
                  let value = body["value"] as? String else { return nil }
            switch encoding {
            case "utf8": request.httpBody = Data(value.utf8)
            case "base64":
                guard let data = Data(base64Encoded: value) else { return nil }
                request.httpBody = data
            default: return nil
            }
        }
        return request
    }

    private static func isSupportedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func failure(code: String, message: String) -> [String: Any] {
        ["ok": false, "error": ["code": code, "message": message]]
    }

    private static func javaScriptArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let result = String(data: data, encoding: .utf8) else { return "[]" }
        return result
    }
}
