import AppKit
import Darwin
import WebKit

@MainActor
enum SessionAsync {
    // Both the timeout and completion are delivered on the host's main thread.
    static func result<T>(timeout: TimeInterval, _ operation: @MainActor (@escaping @MainActor @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let expiry = DispatchWorkItem {
                guard !finished else { return }
                finished = true
                continuation.resume(throwing: SessionError(code: "timeout", message: "The preview operation timed out."))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, timeout), execute: expiry)
            operation { value in
                guard !finished else { return }
                finished = true
                expiry.cancel()
                continuation.resume(with: value)
            }
        }
    }
}

private struct SessionParameters {
    let values: [String: Any]

    init(_ params: [String: QAJSONValue]) { values = params.mapValues(\.foundationValue) }
    func string(_ key: String) -> String? { values[key] as? String }
    func required(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else { throw SessionError.invalid("Missing \(key).") }
        return value
    }
    func number(_ key: String, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
        guard let value = values[key] else { return fallback }
        guard let number = value as? Double, number.isFinite, range.contains(number) else {
            throw SessionError.invalid("\(key) must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return number
    }
    func flag(_ key: String) -> Bool { values[key] as? Bool == true }
}

// One main-thread host owns one WebKit page and one command queue. A helper
// process remains alive between CLI invocations; pages keep their exact state.
@MainActor
final class SessionHost: NSObject, @preconcurrency DevicePreviewDelegate, @preconcurrency DevServerControllerDelegate {
    private let id: String
    private let store: SessionStore
    private let directory: URL
    private let startup: SessionStartup
    private var manifest: SessionManifest
    private let preview: DevicePreviewView
    private let window: NSWindow
    private let input: SessionInput
    private let server = DevServerController()
    private var source: QASourceConfiguration
    private var pollTimer: Timer?
    private var signals: [DispatchSourceSignal] = []
    private var lastActivity = Date()
    private var busy = false
    private var ready = false
    private var loaded = false
    private var navigationError: String?
    private var title: String?
    private var shuttingDown = false
    private var shouldExit = false
    private var recorder: LivePreviewVideoRecorder?
    private var videoState = "idle"
    private var videoPath: String?
    private var videoError: Error?

    static func serve(id: String, store: SessionStore) throws -> Int32 {
        let id = try SessionStore.canonicalID(id)
        let directory = try store.folder(id)
        let lockFD = open(directory.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw SessionError.invalid("Could not open session host lock.") }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw SessionError.invalid("A host already owns this session.") }
        _ = setsid()
        signal(SIGHUP, SIG_IGN)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let startup = try store.read(SessionStartup.self, from: directory.appendingPathComponent("startup.json"))
        let host = try SessionHost(id: id, store: store, startup: startup)
        host.start()
        while !host.shouldExit {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }
        return host.manifest.state == "failed" ? 1 : 0
    }

    private init(id: String, store: SessionStore, startup: SessionStartup) throws {
        self.id = id
        self.store = store
        directory = try store.folder(id)
        self.startup = startup
        source = startup.source
        manifest = SessionManifest(id: id, pid: getpid(), state: "starting", createdAt: Date())
        let configuration = startup.configuration
        preview = DevicePreviewView(profile: configuration.profile,
                                    networkShapingConfiguration: configuration.network ?? .disabled,
                                    nativeHTTPConfiguration: configuration.nativeHTTP ?? .disabled,
                                    dataStore: .nonPersistent())
        input = SessionInput(preview: preview)
        preview.landscape = configuration.orientation == "landscape"
        preview.safeArea = configuration.safeArea.configuredPortrait
        preview.showSafeArea = configuration.safeArea.guideVisible
        preview.applySafeAreaToPage = configuration.safeArea.forcedIntoPageLayout
        preview.showsDeviceFrame = startup.includeDeviceFrame
        preview.headerHTML = configuration.header.enabled ? configuration.header.html : nil
        preview.headerHeight = configuration.header.heightCSSPixels
        preview.headerBaseURL = configuration.header.baseURL.flatMap(URL.init(string:))
        preview.footerHTML = configuration.footer.enabled ? configuration.footer.html : nil
        preview.footerHeight = configuration.footer.heightCSSPixels
        preview.footerBaseURL = configuration.footer.baseURL.flatMap(URL.init(string:))
        if let left = configuration.left {
            preview.leftHTML = left.enabled ? left.html : nil
            preview.leftWidth = left.reservedExtentCSSPixels
            preview.leftBaseURL = left.baseURL.flatMap(URL.init(string:))
        }
        if let right = configuration.right {
            preview.rightHTML = right.enabled ? right.html : nil
            preview.rightWidth = right.reservedExtentCSSPixels
            preview.rightBaseURL = right.baseURL.flatMap(URL.init(string:))
        }
        preview.frame = CGRect(origin: .zero, size: preview.logicalSize)
        preview.bounds = preview.frame
        preview.autoresizingMask = [.width, .height]
        window = CLIPreviewWindow.make(contentView: preview, size: preview.logicalSize, showPreview: false)
        super.init()
        preview.delegate = self
        server.delegate = self
        if let error = preview.networkShapingSetupError { window.close(); throw error }
        guard preview.enableOffscreenRendering(), preview.enableSilentAudioVerification() else {
            window.close()
            throw SessionError(code: "hidden_rendering_unavailable", message: "Active offscreen rendering and page audio muting are required for sessions.")
        }
        preview.layoutSubtreeIfNeeded()
    }

    private func start() {
        try? saveManifest()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        for code in [SIGTERM, SIGINT] {
            signal(code, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: code, queue: .main)
            signalSource.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self, !self.shuttingDown else { return }
                    await self.shutdown()
                    self.shouldExit = true
                }
            }
            signalSource.resume()
            signals.append(signalSource)
        }
        Task {
            do {
                let deadline = Date().addingTimeInterval(startup.timeout)
                try loadSource()
                try await waitForLoad(timeout: startup.timeout)
                try await wait(selector: startup.waitSelector, javascript: startup.waitJavaScript,
                               seconds: startup.settleDelay, timeout: max(0, deadline.timeIntervalSinceNow))
                if let script = startup.prepareJavaScript {
                    guard Date() < deadline else { throw SessionError(code: "timeout", message: "Session startup timed out.") }
                    _ = try await evaluate(script, timeout: deadline.timeIntervalSinceNow)
                }
                guard !shuttingDown else { return }
                ready = true
                manifest.state = "ready"
                lastActivity = Date()
                try saveManifest()
            } catch {
                guard !shuttingDown else { return }
                await shutdown()
                manifest.state = "failed"
                manifest.error = error.localizedDescription
                try? saveManifest()
                shouldExit = true
            }
        }
    }

    private func saveManifest() throws { try store.write(manifest, to: directory.appendingPathComponent("manifest.json")) }

    private func poll() {
        guard !busy, !shuttingDown else { return }
        if ready, Date().timeIntervalSince(lastActivity) > startup.idleTimeout {
            busy = true
            Task { await self.shutdown(); self.shouldExit = true }
            return
        }
        let requests = directory.appendingPathComponent("requests")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: requests.path),
              let name = names.filter({ $0.hasSuffix(".json") && !$0.hasPrefix(".") }).sorted().first else { return }
        let path = requests.appendingPathComponent(name)
        guard let request = try? store.read(SessionRequest.self, from: path) else {
            try? FileManager.default.removeItem(at: path)
            return
        }
        try? FileManager.default.removeItem(at: path)
        guard UUID(uuidString: request.id) != nil else { return }
        busy = true
        lastActivity = Date()
        Task {
            let responseURL = directory.appendingPathComponent("responses").appendingPathComponent(request.id + ".json")
            do {
                guard Date() < request.deadline else { throw SessionError(code: "timeout", message: "Request expired before execution.") }
                guard ready || ["status", "stop"].contains(request.method) else {
                    throw SessionError(code: "not_ready", message: "The session is still loading.")
                }
                let result = try await perform(request.method, params: request.params, deadline: request.deadline)
                let response = SessionResponse(id: request.id, session: id, ok: true, result: QAJSONValue(any: result), error: nil)
                guard try JSONEncoder().encode(response).count <= 4 * 1024 * 1024 else {
                    throw SessionError(code: "result_too_large", message: "Session results must be smaller than 4 MiB. Return a smaller JSON value.")
                }
                try store.write(response, to: responseURL)
            } catch {
                try? store.write(SessionResponse.failure(id: request.id, session: id, error: error), to: responseURL)
            }
            lastActivity = Date()
            busy = false
            if request.method == "stop" { shouldExit = true }
        }
    }

    private func loadSource() throws {
        if let path = source.staticHTMLPath { preview.loadLocalFile(URL(fileURLWithPath: path)); return }
        if let project = source.projectPath {
            let folder = URL(fileURLWithPath: project)
            if let command = source.customCommand { try server.startCommand(folder: folder, command: command) }
            else { try server.start(folder: folder, script: source.npmScript ?? "dev") }
            return
        }
        guard let url = source.finalURL ?? source.requestedURL else { throw SessionError.invalid("Missing preview source.") }
        preview.load(url)
    }

    private func waitForLoad(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !loaded {
            if shuttingDown { throw SessionError(code: "session_closed", message: "Session is closing.") }
            if let navigationError { throw SessionError(code: "navigation_failed", message: navigationError) }
            guard Date() < deadline else { throw SessionError(code: "timeout", message: "Page navigation timed out.") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func evaluate(_ source: String, timeout: TimeInterval = 30) async throws -> Any {
        try await SessionAsync.result(timeout: timeout) { completion in
            preview.sessionInputView.callAsyncJavaScript("return await (0, eval)(source);", arguments: ["source": source],
                                                        in: nil, in: .page, completionHandler: completion)
        }
    }

    private func wait(selector: String?, javascript: String?, seconds: Double, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        if let selector, selector.isEmpty { throw SessionError.invalid("Selector cannot be empty.") }
        while selector != nil || javascript != nil {
            if shuttingDown { throw SessionError(code: "session_closed", message: "Session is closing.") }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SessionError(code: "timeout", message: "Wait condition did not become true.") }
            var satisfied = true
            if let selector {
                let exists = try await evaluate("document.querySelector(\(Self.jsonString(selector))) !== null", timeout: min(remaining, 2))
                satisfied = (exists as? Bool) == true
            }
            if let javascript, satisfied {
                satisfied = (try await evaluate("Boolean(\(javascript))", timeout: min(deadline.timeIntervalSinceNow, 2)) as? Bool) == true
            }
            if satisfied { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard seconds <= deadline.timeIntervalSinceNow else { throw SessionError(code: "timeout", message: "Delay exceeds the request timeout.") }
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }

    private func target(_ p: SessionParameters, timeout: TimeInterval) async throws -> (CGPoint, CGSize) {
        let selector = p.string("selector")
        let script = """
        (() => {
          let x = \(try p.number("x", default: 0, range: -100000...100000));
          let y = \(try p.number("y", default: 0, range: -100000...100000));
          const selector = \(selector.map(Self.jsonString) ?? "null");
          if (selector !== null) {
            const element = document.querySelector(selector);
            if (!element) throw new Error('No element matches ' + selector);
            element.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
            const rect = element.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) throw new Error('Element has no visible area');
            x = Math.max(0, rect.left) + (Math.min(innerWidth, rect.right) - Math.max(0, rect.left)) / 2;
            y = Math.max(0, rect.top) + (Math.min(innerHeight, rect.bottom) - Math.max(0, rect.top)) / 2;
          }
          return {x, y, width: innerWidth, height: innerHeight};
        })()
        """
        if selector == nil, p.values["x"] == nil || p.values["y"] == nil {
            throw SessionError.invalid("Provide a selector or both x and y coordinates.")
        }
        guard let value = try await evaluate(script, timeout: timeout) as? [String: Any],
              let x = value["x"] as? Double, let y = value["y"] as? Double,
              let width = value["width"] as? Double, let height = value["height"] as? Double,
              x >= 0, y >= 0, x < width, y < height else {
            throw SessionError.invalid("The input target is outside the page viewport.")
        }
        return (CGPoint(x: x, y: y), CGSize(width: width, height: height))
    }

    private func perform(_ method: String, params: [String: QAJSONValue], deadline: Date) async throws -> Any {
        let p = SessionParameters(params)
        let timeout = max(0.1, min(120, deadline.timeIntervalSinceNow))
        switch method {
        case "status": return status()
        case "stop":
            await shutdown()
            return ["state": "closed", "recording": recordingInfo()]
        case "inspect":
            let audit = try await SessionAsync.result(timeout: timeout, preview.captureAudit)
            return ["audit": audit, "preview": previewInfo(), "audio": preview.silentAudioVerificationReport(),
                    "nativeHttp": preview.nativeHTTPReport()]
        case "eval":
            let script: String
            if let path = p.string("script-file") { script = try String(contentsOfFile: path, encoding: .utf8) }
            else { script = try p.required("js") }
            return ["value": try await evaluate(script, timeout: timeout)]
        case "wait":
            guard p.string("selector") != nil || p.string("js") != nil || p.values["seconds"] != nil else {
                throw SessionError.invalid("Wait requires selector, js, or seconds.")
            }
            try await wait(selector: p.string("selector"), javascript: p.string("js"),
                           seconds: p.number("seconds", default: 0, range: 0...120), timeout: timeout)
            return ["satisfied": true]
        case "screenshot":
            let output = try outputURL(p, extension: "png")
            let scale = try p.number("scale", default: min(3, max(0.5, preview.profile.viewport.dpr)), range: 0.5...3)
            let image = try await SessionAsync.result(timeout: timeout) { preview.captureVideoFrame(scale: scale, completion: $0) }
            try PreviewImageEncoding.pngData(image).write(to: output, options: .atomic)
            let size = PreviewImageEncoding.pixelSize(of: image)
            return ["path": output.path, "width": size.width, "height": size.height, "preview": previewInfo()]
        case "click", "pointer", "type":
            if method == "type", p.string("selector") == nil { try input.type(p.required("text")) }
            else {
                let (point, viewport) = try await target(p, timeout: timeout)
                let button = Int(try p.number("button", default: 0, range: 0...2))
                if method == "pointer" {
                    try input.pointer(action: p.string("action") ?? "move", point: point, viewport: viewport, button: button)
                } else {
                    let count = Int(try p.number("click-count", default: 1, range: 1...3))
                    for index in 1...count {
                        try input.pointer(action: "down", point: point, viewport: viewport, button: button, clickCount: index)
                        try input.pointer(action: "up", point: point, viewport: viewport, button: button, clickCount: index)
                    }
                    if method == "type" {
                        try await Task.sleep(for: .milliseconds(30))
                        try input.type(p.required("text"))
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(20))
            return ["input": "native", "accepted": true]
        case "drag":
            let from = CGPoint(x: try p.number("from-x", default: -1, range: 0...100000),
                               y: try p.number("from-y", default: -1, range: 0...100000))
            let to = CGPoint(x: try p.number("to-x", default: -1, range: 0...100000),
                             y: try p.number("to-y", default: -1, range: 0...100000))
            let duration = try p.number("duration", default: 0.3, range: 0...min(timeout, 30))
            let steps = Int(try p.number("steps", default: max(2, duration * 30), range: 2...300))
            let (_, viewport) = try await target(SessionParameters(["x": .number(from.x), "y": .number(from.y)]), timeout: timeout)
            guard from.x >= 0, from.y >= 0, to.x >= 0, to.y >= 0, to.x < viewport.width, to.y < viewport.height else {
                throw SessionError.invalid("Drag coordinates must be inside the page viewport.")
            }
            try input.pointer(action: "down", point: from, viewport: viewport)
            defer { try? input.pointer(action: "up", point: to, viewport: viewport) }
            for step in 1...steps {
                guard Date() < deadline else { throw SessionError(code: "timeout", message: "Drag timed out.") }
                let fraction = Double(step) / Double(steps)
                try input.pointer(action: "move", point: CGPoint(x: from.x + (to.x - from.x) * fraction,
                                                                 y: from.y + (to.y - from.y) * fraction), viewport: viewport)
                if duration > 0 { try await Task.sleep(for: .seconds(duration / Double(steps))) }
            }
            return ["input": "native", "accepted": true]
        case "key":
            let key = try p.required("key")
            let action = p.string("action") ?? "press"
            guard ["press", "down", "up"].contains(action) else { throw SessionError.invalid("Key action must be down, up, or press.") }
            let code = try p.values["key-code"].map { _ in Int(try p.number("key-code", default: 0, range: 0...127)) }
            try input.key(key, action: action == "up" ? "up" : "down", modifiers: p.string("modifiers") ?? "", keyCode: code)
            if action == "press" {
                defer { try? input.key(key, action: "up", modifiers: p.string("modifiers") ?? "", keyCode: code) }
                let hold = try p.number("hold", default: 0.02, range: 0...min(timeout, 30))
                try await Task.sleep(for: .seconds(hold))
            }
            return ["input": "native", "heldKeys": input.pressedKeys]
        case "scroll":
            if let selector = p.string("selector") {
                _ = try await evaluate("document.querySelector(\(Self.jsonString(selector)))?.scrollIntoView({block:'center',behavior:'instant'})", timeout: timeout)
            }
            let x = try p.number("x", default: 0, range: -100000...100000)
            let y = try p.number("y", default: 0, range: -100000...100000)
            _ = try await evaluate("window.scrollBy({left:\(x),top:\(y),behavior:'instant'}); ({x:scrollX,y:scrollY})", timeout: timeout)
            return ["input": "javascript", "accepted": true]
        case "navigate", "reload":
            guard recorder == nil else { throw SessionError.invalid("Stop recording before navigating or reloading.") }
            input.releaseAll()
            loaded = false
            navigationError = nil
            if method == "reload" { preview.reload() }
            else if let path = p.string("file") {
                guard FileManager.default.fileExists(atPath: path) else { throw SessionError.invalid("File does not exist: \(path)") }
                preview.loadLocalFile(URL(fileURLWithPath: path))
            } else {
                let raw = try p.required("url")
                guard PreviewNavigationPolicy.normalizedWebURL(from: raw) != nil else { throw SessionError.invalid("Expected an HTTP or HTTPS URL.") }
                preview.load(raw)
            }
            try await waitForLoad(timeout: timeout)
            try await wait(selector: p.string("wait-for"), javascript: p.string("wait-js"), seconds: 0, timeout: max(0.1, deadline.timeIntervalSinceNow))
            return status()
        case "configure":
            guard recorder == nil else { throw SessionError.invalid("Stop recording before changing device geometry.") }
            input.releaseAll()
            var profile = preview.profile
            if let device = p.string("device") {
                guard let match = (BuiltinDevices.all + CustomDeviceSetupStore.load().map(\.profile)).first(where: { $0.id == device }) else {
                    throw SessionError.invalid("Unknown device ID: \(device)")
                }
                profile = match
            }
            profile.viewport.width = try p.number("width", default: profile.viewport.width, range: 1...8192)
            profile.viewport.height = try p.number("height", default: profile.viewport.height, range: 1...8192)
            profile.viewport.dpr = try p.number("dpr", default: profile.viewport.dpr, range: 0.5...3)
            let orientation = p.string("orientation") ?? (preview.landscape ? "landscape" : "portrait")
            guard ["portrait", "landscape"].contains(orientation) else { throw SessionError.invalid("Orientation must be portrait or landscape.") }
            let reload = profile != preview.profile
            if reload { loaded = false; navigationError = nil; preview.profile = profile }
            preview.landscape = orientation == "landscape"
            if p.flag("include-device-frame") { preview.showsDeviceFrame = true }
            if p.flag("hide-device-frame") { preview.showsDeviceFrame = false }
            resizeWindow()
            if reload { try await waitForLoad(timeout: timeout) }
            try await Task.sleep(for: .milliseconds(100))
            return status()
        case "record.start":
            guard recorder == nil else { throw SessionError.invalid("A recording is already active.") }
            let output = try outputURL(p, extension: "mp4")
            let fps = Int(try p.number("fps", default: 30, range: 1...30))
            let scale = try p.number("scale", default: min(3, max(0.5, preview.profile.viewport.dpr)), range: 0.5...3)
            videoState = "recording"
            videoPath = output.path
            videoError = nil
            let recorder = LivePreviewVideoRecorder(outputURL: output, duration: nil, framesPerSecond: fps,
                                                    captureScale: scale, overwrite: p.flag("overwrite"), quality: .high)
            self.recorder = recorder
            recorder.record(preview: preview) { [weak self] result in
                guard let self else { return }
                self.recorder = nil
                switch result {
                case .success: self.videoState = "saved"
                case .failure(let error): self.videoState = "failed"; self.videoError = error
                }
            }
            return recordingInfo()
        case "record.stop":
            try await stopRecording(timeout: timeout)
            return recordingInfo()
        default: throw SessionError.invalid("Unknown session method: \(method)")
        }
    }

    private func outputURL(_ p: SessionParameters, extension suffix: String) throws -> URL {
        let path = try p.required("output")
        guard path.hasPrefix("/") else { throw SessionError.invalid("Output paths must be absolute.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == suffix else { throw SessionError.invalid("Expected a .\(suffix) output path.") }
        if FileManager.default.fileExists(atPath: path), !p.flag("overwrite") { throw CLIError.outputExists(path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private func stopRecording(timeout: TimeInterval) async throws {
        guard videoPath != nil else { throw SessionError.invalid("No recording has been started.") }
        if videoState == "recording" { videoState = "saving"; recorder?.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        while recorder != nil {
            guard Date() < deadline else { throw SessionError(code: "timeout", message: "Video is still saving. Check session status.") }
            try await Task.sleep(for: .milliseconds(25))
        }
        if let videoError { throw videoError }
    }

    private func recordingInfo() -> [String: Any] {
        var value: [String: Any] = ["state": videoState]
        if let videoPath { value["path"] = videoPath }
        if let videoError { value["error"] = videoError.localizedDescription }
        return value
    }

    private func previewInfo() -> [String: Any] {
        let frame = preview.sessionPageFrame
        return ["visibility": "hidden", "windowIntersectsDisplay": CLIPreviewWindow.intersectsDisplay(window),
                "captureBackend": "windowCompositor", "offscreenRenderingEnabled": preview.offscreenRenderingEnabled,
                "deviceFrameIncluded": preview.showsDeviceFrame, "coordinateSystem": "mainPageCSSPixels",
                "pageFrame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]]
    }

    private func status() -> [String: Any] {
        ["session": id, "pid": getpid(), "state": shuttingDown ? "closed" : ready ? "ready" : "starting",
         "url": preview.currentURL?.absoluteString ?? "", "title": title ?? "", "loaded": loaded,
         "device": preview.profile.id, "orientation": preview.landscape ? "landscape" : "portrait",
         "viewport": ["width": preview.logicalViewportSize.width, "height": preview.logicalViewportSize.height,
                      "dpr": preview.profile.viewport.dpr],
         "preview": previewInfo(), "audio": preview.silentAudioVerificationReport(),
         "storage": "isolatedEphemeralSession", "heldKeys": input.pressedKeys, "recording": recordingInfo(),
         "idleTimeoutSeconds": startup.idleTimeout]
    }

    private func resizeWindow() {
        let size = preview.logicalSize
        let origin = CLIPreviewWindow.origin(showPreview: false, windowSize: size, screenFrames: NSScreen.screens.map(\.frame), mainVisibleFrame: NSScreen.main?.visibleFrame)
        window.setFrame(CGRect(origin: origin, size: size), display: false)
        preview.frame = CGRect(origin: .zero, size: size)
        preview.bounds = preview.frame
        preview.layoutSubtreeIfNeeded()
    }

    private func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        input.releaseAll()
        if recorder != nil { try? await stopRecording(timeout: 5) }
        server.stop()
        let deadline = Date().addingTimeInterval(3)
        while server.state == .stopping, Date() < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        pollTimer?.invalidate()
        window.close()
        manifest.state = "closed"
        try? saveManifest()
    }

    private static func jsonString(_ string: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: string, options: .fragmentsAllowed), as: UTF8.self)
    }

    func previewDidStartLoading() { loaded = false }
    func previewDidFinishLoading(title: String?, url: URL?) {
        guard let url else { return }
        self.title = title
        source.finalURL = url.absoluteString
        loaded = true
        navigationError = nil
    }
    func previewDidFail(_ message: String) { navigationError = message; loaded = false }
    func devServerStateChanged(_ state: DevServerState, url: URL?) {
        if state == .running, let url {
            preview.loadLocalServer(CLIPath.appending(route: source.route, to: url).absoluteString, resetSiteData: false)
        } else if state == .failed { navigationError = "The managed development server exited." }
    }
    func devServerDidOutput(_ line: String, isError: Bool) { print(line); fflush(stdout) }
}
