import AppKit
import CryptoKit
import Foundation

enum QAJSONValue: Codable, Equatable {
    case object([String: QAJSONValue])
    case array([QAJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(any value: Any) {
        switch value {
        case let value as [String: Any]:
            self = .object(value.mapValues(QAJSONValue.init(any:)))
        case let value as [Any]:
            self = .array(value.map(QAJSONValue.init(any:)))
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            self = CFGetTypeID(value) == CFBooleanGetTypeID()
                ? .bool(value.boolValue)
                : .number(value.doubleValue)
        default:
            self = .null
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: QAJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([QAJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct QASize: Codable, Equatable {
    var width: Double
    var height: Double

    init(_ size: CGSize) {
        width = size.width
        height = size.height
    }

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

struct QARect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init?(dictionary: [String: Any]?) {
        guard let dictionary else { return nil }
        x = dictionary.double("x")
        y = dictionary.double("y")
        width = dictionary.double("width")
        height = dictionary.double("height")
    }
}

struct QAGenerator: Codable, Equatable {
    var name: String
    var version: String
    var operatingSystem: String
    var locale: String
    var timeZone: String
    var renderer: String
}

struct QASourceConfiguration: Codable, Equatable {
    var requestedURL: String?
    var finalURL: String?
    var pageTitle: String?
    var projectPath: String?
    var launchMode: String?
    var npmScript: String?
    var customCommand: String?
    var staticHTMLPath: String?
}

struct QALayerConfiguration: Codable, Equatable {
    var enabled: Bool
    var kind: HTMLLayerKind
    var identifier: String?
    var name: String?
    var sourcePath: String?
    var baseURL: String?
    var heightCSSPixels: Double
    var widthCSSPixels: Double? = nil
    var html: String?
    var htmlSHA256: String?

    var reservedExtentCSSPixels: Double {
        kind.isSide ? (widthCSSPixels ?? heightCSSPixels) : heightCSSPixels
    }

    init(
        kind: HTMLLayerKind,
        html: String?,
        height: CGFloat,
        sourcePath: String?,
        baseURL: URL?,
        identifier: String? = nil,
        name: String? = nil
    ) {
        enabled = html != nil
        self.kind = kind
        self.identifier = identifier
        self.name = name
        self.sourcePath = sourcePath
        self.baseURL = baseURL?.absoluteString
        if kind.isSide {
            heightCSSPixels = 0
            widthCSSPixels = html == nil ? 0 : height
        } else {
            heightCSSPixels = html == nil ? 0 : height
            widthCSSPixels = nil
        }
        self.html = html
        htmlSHA256 = html.map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

struct QAResolutionConfiguration: Codable, Equatable {
    var profilePortraitCSS: QASize
    var orientedScreenCSS: QASize
    var pageContentCSS: QASize
    var devicePixelRatio: Double
    var orientedScreenPhysicalPixels: QASize
    var pageContentPhysicalPixels: QASize
}

struct QASafeAreaConfiguration: Codable, Equatable {
    var configuredPortrait: EdgeInsets
    var orientedDevice: EdgeInsets
    var exposedToPage: EdgeInsets
    var guideVisible: Bool
    var forcedIntoPageLayout: Bool
    var implementation: String
}

struct QASafariConfiguration: Codable, Equatable {
    var enabled: Bool
    var simulatedBrowser: String
    var renderingEngine: String
    var userAgent: String
    var topChromeCSSPixels: Double
    var bottomChromeCSSPixels: Double
}

struct QADeviceConfiguration: Codable, Equatable {
    var profile: DeviceProfile
    var orientation: String
    var resolution: QAResolutionConfiguration
    var safeArea: QASafeAreaConfiguration
    var safari: QASafariConfiguration
    var network: NetworkShapingConfiguration? = nil
    var header: QALayerConfiguration
    var footer: QALayerConfiguration
    var left: QALayerConfiguration? = nil
    var right: QALayerConfiguration? = nil
}

struct QATargetHint: Codable, Equatable {
    var selector: String?
    var tagName: String?
    var id: String?
    var className: String?
    var role: String?
    var ariaLabel: String?
    var name: String?
    var text: String?
    var isCanvas: Bool
    var rectangle: QARect?

    init?(dictionary: [String: Any]?) {
        guard let dictionary else { return nil }
        selector = dictionary.string("selector")
        tagName = dictionary.string("tagName")
        id = dictionary.string("id")
        className = dictionary.string("className")
        role = dictionary.string("role")
        ariaLabel = dictionary.string("ariaLabel")
        name = dictionary.string("name")
        text = dictionary.string("text")
        isCanvas = dictionary.bool("isCanvas")
        rectangle = QARect(dictionary: dictionary["rectangle"] as? [String: Any])
    }
}

struct QAPointerInput: Codable, Equatable {
    var clientX: Double
    var clientY: Double
    var normalizedX: Double
    var normalizedY: Double
    var pageX: Double
    var pageY: Double
    var screenX: Double
    var screenY: Double
    var movementX: Double
    var movementY: Double
    var button: Int
    var buttons: Int
    var detail: Int
    var pointerID: Int
    var pointerType: String
    var isPrimary: Bool
    var pressure: Double
    var tangentialPressure: Double
    var tiltX: Int
    var tiltY: Int
    var twist: Int
    var width: Double
    var height: Double

    init?(dictionary: [String: Any]?) {
        guard let dictionary else { return nil }
        clientX = dictionary.double("clientX")
        clientY = dictionary.double("clientY")
        normalizedX = dictionary.double("normalizedX")
        normalizedY = dictionary.double("normalizedY")
        pageX = dictionary.double("pageX")
        pageY = dictionary.double("pageY")
        screenX = dictionary.double("screenX")
        screenY = dictionary.double("screenY")
        movementX = dictionary.double("movementX")
        movementY = dictionary.double("movementY")
        button = dictionary.int("button")
        buttons = dictionary.int("buttons")
        detail = dictionary.int("detail")
        pointerID = dictionary.int("pointerID")
        pointerType = dictionary.string("pointerType") ?? "mouse"
        isPrimary = dictionary.bool("isPrimary")
        pressure = dictionary.double("pressure")
        tangentialPressure = dictionary.double("tangentialPressure")
        tiltX = dictionary.int("tiltX")
        tiltY = dictionary.int("tiltY")
        twist = dictionary.int("twist")
        width = dictionary.double("width")
        height = dictionary.double("height")
    }
}

struct QAKeyboardInput: Codable, Equatable {
    var key: String
    var code: String
    var location: Int
    var repeatKey: Bool
    var isComposing: Bool
    var keyCode: Int
    var charCode: Int
    var alt: Bool
    var control: Bool
    var meta: Bool
    var shift: Bool

    init?(dictionary: [String: Any]?) {
        guard let dictionary else { return nil }
        key = dictionary.string("key") ?? ""
        code = dictionary.string("code") ?? ""
        location = dictionary.int("location")
        repeatKey = dictionary.bool("repeat")
        isComposing = dictionary.bool("isComposing")
        keyCode = dictionary.int("keyCode")
        charCode = dictionary.int("charCode")
        alt = dictionary.bool("altKey")
        control = dictionary.bool("ctrlKey")
        meta = dictionary.bool("metaKey")
        shift = dictionary.bool("shiftKey")
    }
}

struct QAFormInput: Codable, Equatable {
    var value: String?
    var inputType: String?
    var data: String?
    var checked: Bool?
    var selectionStart: Int?
    var selectionEnd: Int?
    var redacted: Bool

    init?(dictionary: [String: Any]?) {
        guard let dictionary else { return nil }
        value = dictionary.string("value")
        inputType = dictionary.string("inputType")
        data = dictionary.string("data")
        checked = dictionary.optionalBool("checked")
        selectionStart = dictionary.optionalInt("selectionStart")
        selectionEnd = dictionary.optionalInt("selectionEnd")
        redacted = dictionary.bool("redacted")
    }
}

struct QAWaitCondition: Codable, Equatable {
    var selector: String?
    var javascript: String?
    var delayMilliseconds: Double?
    var timeoutMilliseconds: Double?
    var pollIntervalMilliseconds: Double?

    init(
        selector: String? = nil,
        javascript: String? = nil,
        delayMilliseconds: Double? = nil,
        timeoutMilliseconds: Double? = nil,
        pollIntervalMilliseconds: Double? = nil
    ) {
        self.selector = selector
        self.javascript = javascript
        self.delayMilliseconds = delayMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
    }

    init?(dictionary: [String: Any]?) {
        guard let dictionary else { return nil }
        selector = dictionary.string("selector")
        javascript = dictionary.string("javascript")
        delayMilliseconds = dictionary.optionalDouble("delayMilliseconds")
        timeoutMilliseconds = dictionary.optionalDouble("timeoutMilliseconds")
        pollIntervalMilliseconds = dictionary.optionalDouble("pollIntervalMilliseconds")
    }
}

struct QAInputEvent: Codable, Equatable, Identifiable {
    var id: String
    var type: String
    var atMilliseconds: Double
    var intervalSincePreviousMilliseconds: Double
    var pageURL: String?
    var viewportCSS: QASize
    var pointer: QAPointerInput?
    var keyboard: QAKeyboardInput?
    var form: QAFormInput?
    var wait: QAWaitCondition?
    var target: QATargetHint?

    init?(message: [String: Any], previousAt: Double) {
        guard let type = message.string("type"),
              let at = message.optionalDouble("atMilliseconds") else { return nil }
        id = message.string("id") ?? UUID().uuidString
        self.type = type
        atMilliseconds = max(0, at)
        intervalSincePreviousMilliseconds = max(0, atMilliseconds - previousAt)
        pageURL = message.string("pageURL")
        let viewport = message["viewport"] as? [String: Any] ?? [:]
        viewportCSS = QASize(
            width: viewport.double("width"),
            height: viewport.double("height")
        )
        pointer = QAPointerInput(dictionary: message["pointer"] as? [String: Any])
        keyboard = QAKeyboardInput(dictionary: message["keyboard"] as? [String: Any])
        form = QAFormInput(dictionary: message["form"] as? [String: Any])
        wait = QAWaitCondition(dictionary: message["wait"] as? [String: Any])
        target = QATargetHint(dictionary: message["target"] as? [String: Any])
    }
}

struct QAPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var normalizedX: Double
    var normalizedY: Double
}

struct QAGesture: Codable, Equatable, Identifiable {
    var id: String
    var type: String
    var direction: String?
    var pointerType: String
    var atMilliseconds: Double
    var intervalSincePreviousGestureMilliseconds: Double
    var durationMilliseconds: Double
    var distanceCSSPixels: Double
    var start: QAPoint
    var end: QAPoint
    var samples: [QAPoint]
    var sourceEventIDs: [String]
    var target: QATargetHint?
}

struct QACheckpoint: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var atMilliseconds: Double
    var intervalSincePreviousInputMilliseconds: Double
    var screenshotPath: String
    var screenshotPixelSize: QASize
    var captureScale: Double
}

struct QAArtifact: Codable, Equatable {
    var kind: String
    var path: String
    var mediaType: String
    var createdAt: Date
}

struct QATiming: Codable, Equatable {
    var clock: String
    var recordedAt: Date
    var finishedAt: Date
    var durationMilliseconds: Double
    var eventCount: Int
    var gestureCount: Int?
    var checkpointCount: Int
}

struct QAScenario: Codable, Equatable, Identifiable {
    var schemaVersion: Int
    var id: String
    var name: String
    var generator: QAGenerator
    var source: QASourceConfiguration
    var configuration: QADeviceConfiguration
    var environmentAtStart: QAJSONValue?
    var environmentAtEnd: QAJSONValue?
    var auditAtEnd: QAJSONValue?
    var timing: QATiming
    var events: [QAInputEvent]
    var gestures: [QAGesture]?
    var checkpoints: [QACheckpoint]
    var artifacts: [QAArtifact]
    var notes: [String]
    var authoring: QAJSONValue? = nil
}

enum QAScenarioFiles {
    static func load(_ url: URL) throws -> QAScenario {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QAScenario.self, from: Data(contentsOf: url))
    }

    static func save(_ scenario: QAScenario, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(scenario).write(to: url, options: .atomic)
    }
}

final class QAScenarioRecorder {
    private weak var preview: DevicePreviewView?
    private let outputURL: URL
    private let source: QASourceConfiguration
    private let configuration: QADeviceConfiguration
    private var recordedAt = Date()
    private var startedUptime = ProcessInfo.processInfo.systemUptime
    private var environmentAtStart: QAJSONValue?
    private var environmentAtEnd: QAJSONValue?
    private var auditAtEnd: QAJSONValue?
    private var events: [QAInputEvent] = []
    private var checkpoints: [QACheckpoint] = []
    private var artifacts: [QAArtifact] = []
    private var notes: [String] = []
    private var videoRecorder: LivePreviewVideoRecorder?
    private var videoFinished = false
    private var endCaptureFinished = false
    private var stopping = false
    private var completion: ((Result<QAScenario, Error>) -> Void)?

    init(
        preview: DevicePreviewView,
        outputURL: URL,
        source: QASourceConfiguration,
        configuration: QADeviceConfiguration
    ) {
        self.preview = preview
        self.outputURL = outputURL
        self.source = source
        self.configuration = configuration
    }

    func start(captureVideo: Bool = false) {
        guard let preview else { return }
        recordedAt = Date()
        startedUptime = ProcessInfo.processInfo.systemUptime
        preview.qaInputHandler = { [weak self] message in
            self?.receive(message)
        }
        preview.captureQARuntimeEnvironment { [weak self] result in
            if case .success(let value) = result {
                self?.environmentAtStart = QAJSONValue(any: value)
            }
        }
        preview.beginQARecording()

        guard captureVideo else {
            videoFinished = true
            return
        }
        let videoURL = outputURL.deletingPathExtension().appendingPathExtension("mp4")
        let recorder = LivePreviewVideoRecorder(
            outputURL: videoURL,
            duration: nil,
            framesPerSecond: 30,
            captureScale: 1,
            overwrite: true
        )
        videoRecorder = recorder
        recorder.record(preview: preview) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.artifacts.append(QAArtifact(
                    kind: "recordingVideo",
                    path: videoURL.path,
                    mediaType: "video/mp4",
                    createdAt: Date()
                ))
            case .failure(let error):
                self.notes.append("Video capture failed: \(error.localizedDescription)")
            }
            self.videoFinished = true
            self.finishIfReady()
        }
    }

    func addCheckpoint(name: String? = nil, completion: @escaping (Result<QACheckpoint, Error>) -> Void) {
        guard let preview else { return }
        let number = checkpoints.count + 1
        let checkpointName = name ?? "Checkpoint \(number)"
        let screenshotURL = outputURL.deletingPathExtension()
            .appendingPathExtension("checkpoint-\(String(format: "%03d", number)).png")
        let at = elapsedMilliseconds
        preview.captureScreenshot { [weak self] result in
            guard let self else { return }
            do {
                let image = try result.get()
                try PreviewImageEncoding.pngData(image).write(to: screenshotURL, options: .atomic)
                let checkpoint = QACheckpoint(
                    id: UUID().uuidString,
                    name: checkpointName,
                    atMilliseconds: at,
                    intervalSincePreviousInputMilliseconds: max(0, at - (self.events.last?.atMilliseconds ?? 0)),
                    screenshotPath: screenshotURL.path,
                    screenshotPixelSize: QASize(PreviewImageEncoding.pixelSize(of: image)),
                    captureScale: self.configuration.resolution.devicePixelRatio
                )
                self.checkpoints.append(checkpoint)
                self.artifacts.append(QAArtifact(
                    kind: "checkpointScreenshot",
                    path: screenshotURL.path,
                    mediaType: "image/png",
                    createdAt: Date()
                ))
                completion(.success(checkpoint))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stop(completion: @escaping (Result<QAScenario, Error>) -> Void) {
        guard !stopping else { return }
        stopping = true
        self.completion = completion
        preview?.qaInputHandler = nil
        preview?.endQARecording()
        videoRecorder?.stop()

        guard let preview else {
            endCaptureFinished = true
            finishIfReady()
            return
        }
        let group = DispatchGroup()
        group.enter()
        preview.captureQARuntimeEnvironment { [weak self] result in
            if case .success(let value) = result {
                self?.environmentAtEnd = QAJSONValue(any: value)
            }
            group.leave()
        }
        group.enter()
        preview.captureAudit { [weak self] result in
            if case .success(let value) = result {
                self?.auditAtEnd = QAJSONValue(any: value)
            }
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            self?.endCaptureFinished = true
            self?.finishIfReady()
        }
    }

    private var elapsedMilliseconds: Double {
        (ProcessInfo.processInfo.systemUptime - startedUptime) * 1_000
    }

    private func receive(_ message: [String: Any]) {
        guard !stopping else { return }
        let previous = events.last?.atMilliseconds ?? 0
        guard let event = QAInputEvent(message: message, previousAt: previous) else { return }
        events.append(event)
    }

    private func finishIfReady() {
        guard stopping, videoFinished, endCaptureFinished, let completion else { return }
        self.completion = nil
        events.sort { $0.atMilliseconds < $1.atMilliseconds }
        var previous = 0.0
        for index in events.indices {
            events[index].intervalSincePreviousMilliseconds = max(0, events[index].atMilliseconds - previous)
            previous = events[index].atMilliseconds
        }
        let gestures = QAGestureDeriver.derive(from: events)
        let finishedAt = Date()
        let duration = max(
            elapsedMilliseconds,
            events.last?.atMilliseconds ?? 0,
            checkpoints.last?.atMilliseconds ?? 0
        )
        let scenario = QAScenario(
            schemaVersion: 1,
            id: UUID().uuidString,
            name: outputURL.deletingPathExtension().lastPathComponent,
            generator: QAGenerator(
                name: "ViewDeck",
                version: AppInfo.version,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                locale: Locale.current.identifier,
                timeZone: TimeZone.current.identifier,
                renderer: "WKWebView / Apple WebKit"
            ),
            source: source,
            configuration: configuration,
            environmentAtStart: environmentAtStart,
            environmentAtEnd: environmentAtEnd,
            auditAtEnd: auditAtEnd,
            timing: QATiming(
                clock: "monotonic milliseconds from recording start",
                recordedAt: recordedAt,
                finishedAt: finishedAt,
                durationMilliseconds: duration,
                eventCount: events.count,
                gestureCount: gestures.count,
                checkpointCount: checkpoints.count
            ),
            events: events,
            gestures: gestures,
            checkpoints: checkpoints,
            artifacts: artifacts,
            notes: notes
        )
        do {
            try QAScenarioFiles.save(scenario, to: outputURL)
            completion(.success(scenario))
        } catch {
            completion(.failure(error))
        }
    }
}

enum QAGestureDeriver {
    private struct ActiveGesture {
        var down: QAInputEvent
        var samples: [QAInputEvent]
    }

    static func derive(from events: [QAInputEvent]) -> [QAGesture] {
        var active: [Int: ActiveGesture] = [:]
        var gestures: [QAGesture] = []
        var previousGestureAt = 0.0

        for event in events where event.type.hasPrefix("pointer") {
            guard let pointer = event.pointer else { continue }
            switch event.type {
            case "pointerdown":
                active[pointer.pointerID] = ActiveGesture(down: event, samples: [event])
            case "pointermove":
                active[pointer.pointerID]?.samples.append(event)
            case "pointerup", "pointercancel":
                guard var current = active.removeValue(forKey: pointer.pointerID),
                      let startPointer = current.down.pointer else { continue }
                current.samples.append(event)
                let deltaX = pointer.clientX - startPointer.clientX
                let deltaY = pointer.clientY - startPointer.clientY
                let distance = hypot(deltaX, deltaY)
                let duration = max(0, event.atMilliseconds - current.down.atMilliseconds)
                let type: String
                if event.type == "pointercancel" {
                    type = "cancelled"
                } else if distance < 8, duration < 800 {
                    type = pointer.pointerType == "touch" ? "tap" : "click"
                } else if distance >= 24 {
                    type = "swipe"
                } else {
                    type = "drag"
                }
                let direction: String?
                if type == "swipe" || type == "drag" {
                    if abs(deltaX) >= abs(deltaY) {
                        direction = deltaX >= 0 ? "right" : "left"
                    } else {
                        direction = deltaY >= 0 ? "down" : "up"
                    }
                } else {
                    direction = nil
                }
                let gestureAt = current.down.atMilliseconds
                gestures.append(QAGesture(
                    id: UUID().uuidString,
                    type: type,
                    direction: direction,
                    pointerType: startPointer.pointerType,
                    atMilliseconds: gestureAt,
                    intervalSincePreviousGestureMilliseconds: max(0, gestureAt - previousGestureAt),
                    durationMilliseconds: duration,
                    distanceCSSPixels: distance,
                    start: point(startPointer),
                    end: point(pointer),
                    samples: current.samples.compactMap(\.pointer).map(point),
                    sourceEventIDs: current.samples.map(\.id),
                    target: current.down.target
                ))
                previousGestureAt = gestureAt
            default:
                break
            }
        }
        return gestures
    }

    private static func point(_ pointer: QAPointerInput) -> QAPoint {
        QAPoint(
            x: pointer.clientX,
            y: pointer.clientY,
            normalizedX: pointer.normalizedX,
            normalizedY: pointer.normalizedY
        )
    }
}

struct QAPlaybackTimingEntry: Codable, Equatable {
    var id: String
    var kind: String
    var eventType: String?
    var originalAtMilliseconds: Double
    var effectiveAtMilliseconds: Double
    var originalIntervalMilliseconds: Double
    var effectiveIntervalMilliseconds: Double
    var adjustment: String
}

struct QAPlaybackTimingSummary: Codable, Equatable {
    var mode: String
    var originalDurationMilliseconds: Double
    var effectiveDurationMilliseconds: Double
    var savedMilliseconds: Double
    var entries: [QAPlaybackTimingEntry]
}

enum QAPlaybackTimelinePayload: Equatable {
    case event(QAInputEvent)
    case checkpoint(QACheckpoint)
}

struct QAScheduledPlaybackItem: Equatable {
    var payload: QAPlaybackTimelinePayload
    var effectiveAtMilliseconds: Double
}

struct QAPlaybackTimingPlan: Equatable {
    var scheduledItems: [QAScheduledPlaybackItem]
    var summary: QAPlaybackTimingSummary
}

enum QAPlaybackTimingPlanner {
    static let preservedGapLimitMilliseconds = 750.0
    static let compressedIdleGapMilliseconds = 250.0

    static func make(
        events: [QAInputEvent],
        checkpoints: [QACheckpoint],
        speed: Double,
        smart: Bool
    ) -> QAPlaybackTimingPlan {
        var sourceItems = (
            events.map(QAPlaybackTimelinePayload.event)
                + checkpoints.map(QAPlaybackTimelinePayload.checkpoint)
        ).enumerated().map { (order: $0.offset, payload: $0.element) }
        sourceItems.sort {
            let lhs = originalTime(of: $0.payload)
            let rhs = originalTime(of: $1.payload)
            if lhs == rhs { return $0.order < $1.order }
            return lhs < rhs
        }

        var activePointers = Set<Int>()
        var activeMouseButtons = Set<Int>()
        var activeKeys = Set<String>()
        var previousOriginal = 0.0
        var previousEffective = 0.0
        var scheduled: [QAScheduledPlaybackItem] = []
        var entries: [QAPlaybackTimingEntry] = []

        for sourceItem in sourceItems {
            let item = sourceItem.payload
            let originalAt = originalTime(of: item)
            let originalGap = max(0, originalAt - previousOriginal)
            let effectiveAt: Double
            let effectiveGap: Double
            let adjustment: String

            if smart {
                let atomicActionActive = !activePointers.isEmpty
                    || !activeMouseButtons.isEmpty
                    || !activeKeys.isEmpty
                if atomicActionActive {
                    effectiveGap = originalGap
                    adjustment = "atomic-action-preserved"
                } else if originalGap <= preservedGapLimitMilliseconds {
                    effectiveGap = originalGap
                    adjustment = "short-gap-preserved"
                } else {
                    effectiveGap = min(originalGap, compressedIdleGapMilliseconds)
                    adjustment = "idle-gap-capped"
                }
                effectiveAt = previousEffective + effectiveGap
            } else if speed <= 0 {
                effectiveAt = 0
                effectiveGap = 0
                adjustment = "maximum-speed"
            } else {
                effectiveAt = originalAt / speed
                effectiveGap = max(0, effectiveAt - previousEffective)
                adjustment = speed == 1 ? "recorded-timing" : "globally-scaled"
            }

            let identity = identity(of: item)
            entries.append(QAPlaybackTimingEntry(
                id: identity.id,
                kind: identity.kind,
                eventType: identity.eventType,
                originalAtMilliseconds: originalAt,
                effectiveAtMilliseconds: effectiveAt,
                originalIntervalMilliseconds: originalGap,
                effectiveIntervalMilliseconds: effectiveGap,
                adjustment: adjustment
            ))
            scheduled.append(QAScheduledPlaybackItem(
                payload: item,
                effectiveAtMilliseconds: effectiveAt
            ))
            updateAtomicState(
                for: item,
                pointers: &activePointers,
                mouseButtons: &activeMouseButtons,
                keys: &activeKeys
            )
            previousOriginal = originalAt
            previousEffective = effectiveAt
        }

        let mode: String
        if smart {
            mode = "smart"
        } else if speed <= 0 {
            mode = "maximum"
        } else {
            mode = "\(speed)x"
        }
        return QAPlaybackTimingPlan(
            scheduledItems: scheduled,
            summary: QAPlaybackTimingSummary(
                mode: mode,
                originalDurationMilliseconds: previousOriginal,
                effectiveDurationMilliseconds: previousEffective,
                savedMilliseconds: max(0, previousOriginal - previousEffective),
                entries: entries
            )
        )
    }

    private static func originalTime(of item: QAPlaybackTimelinePayload) -> Double {
        switch item {
        case .event(let event): return event.atMilliseconds
        case .checkpoint(let checkpoint): return checkpoint.atMilliseconds
        }
    }

    private static func identity(
        of item: QAPlaybackTimelinePayload
    ) -> (id: String, kind: String, eventType: String?) {
        switch item {
        case .event(let event):
            return (event.id, "event", event.type)
        case .checkpoint(let checkpoint):
            return (checkpoint.id, "checkpoint", nil)
        }
    }

    private static func updateAtomicState(
        for item: QAPlaybackTimelinePayload,
        pointers: inout Set<Int>,
        mouseButtons: inout Set<Int>,
        keys: inout Set<String>
    ) {
        guard case .event(let event) = item else { return }
        if let pointer = event.pointer {
            switch event.type {
            case "pointerdown":
                pointers.insert(pointer.pointerID)
            case "pointerup", "pointercancel":
                pointers.remove(pointer.pointerID)
            case "mousedown":
                mouseButtons.insert(pointer.button)
            case "mouseup":
                mouseButtons.remove(pointer.button)
            default:
                break
            }
        }
        if let keyboard = event.keyboard {
            let identifier = keyboard.code.isEmpty ? keyboard.key : keyboard.code
            switch event.type {
            case "keydown":
                keys.insert(identifier)
            case "keyup":
                keys.remove(identifier)
            default:
                break
            }
        }
    }
}

private enum QAPlaybackError: LocalizedError {
    case waitTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .waitTimedOut(let condition):
            return "Timed out waiting for \(condition)."
        }
    }
}

final class QAPlaybackController {
    struct ResultSummary {
        var eventCount: Int
        var checkpointCount: Int
        var errorMessages: [String]
        var elapsedMilliseconds: Double
        var wasCancelled: Bool
        var timing: QAPlaybackTimingSummary
    }

    private struct Item {
        var payload: QAPlaybackTimelinePayload
        var effectiveAtMilliseconds: Double
    }

    private weak var preview: DevicePreviewView?
    private let scenario: QAScenario
    private let checkpointHandler: (QACheckpoint, @escaping () -> Void) -> Void
    private let completion: (ResultSummary) -> Void
    private let timingSummary: QAPlaybackTimingSummary
    private var items: [Item] = []
    private var index = 0
    private var replayedEventCount = 0
    private var replayedCheckpointCount = 0
    private var errors: [String] = []
    private var startedUptime = 0.0
    private var scheduledWorkItem: DispatchWorkItem?
    private var isFinished = false

    init(
        preview: DevicePreviewView,
        scenario: QAScenario,
        speed: Double,
        smartTiming: Bool = false,
        checkpointHandler: @escaping (QACheckpoint, @escaping () -> Void) -> Void,
        completion: @escaping (ResultSummary) -> Void
    ) {
        self.preview = preview
        self.scenario = scenario
        self.checkpointHandler = checkpointHandler
        self.completion = completion
        let timingPlan = QAPlaybackTimingPlanner.make(
            events: scenario.events,
            checkpoints: scenario.checkpoints,
            speed: speed,
            smart: smartTiming
        )
        timingSummary = timingPlan.summary
        items = timingPlan.scheduledItems.map {
            Item(payload: $0.payload, effectiveAtMilliseconds: $0.effectiveAtMilliseconds)
        }
    }

    func start() {
        guard !isFinished else { return }
        startedUptime = ProcessInfo.processInfo.systemUptime
        runNext()
    }

    func cancel() {
        guard !isFinished else { return }
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        finish(wasCancelled: true)
    }

    private func runNext() {
        guard !isFinished else { return }
        guard index < items.count else {
            finish(wasCancelled: false)
            return
        }
        let item = items[index]
        let targetSeconds = item.effectiveAtMilliseconds / 1_000
        let elapsed = ProcessInfo.processInfo.systemUptime - startedUptime
        let delay = max(0, targetSeconds - elapsed)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isFinished else { return }
            self.scheduledWorkItem = nil
            switch item.payload {
            case .event(let event):
                guard let preview = self.preview else {
                    self.index += 1
                    self.runNext()
                    return
                }
                self.replay(event, in: preview) { result in
                    guard !self.isFinished else { return }
                    if case .failure(let error) = result {
                        self.errors.append("\(event.type) at \(Int(event.atMilliseconds))ms: \(error.localizedDescription)")
                    }
                    self.replayedEventCount += 1
                    self.index += 1
                    self.runNext()
                }
            case .checkpoint(let checkpoint):
                self.checkpointHandler(checkpoint) {
                    guard !self.isFinished else { return }
                    self.replayedCheckpointCount += 1
                    self.index += 1
                    self.runNext()
                }
            }
        }
        scheduledWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func replay(
        _ event: QAInputEvent,
        in preview: DevicePreviewView,
        completion: @escaping (Result<Any?, Error>) -> Void
    ) {
        guard let wait = event.wait else {
            preview.replayQAEvent(event, completion: completion)
            return
        }
        let delay = max(0, wait.delayMilliseconds ?? 0) / 1_000
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak preview] in
            guard let self, !self.isFinished, let preview else { return }
            self.poll(wait, in: preview, completion: completion)
        }
    }

    private func poll(
        _ wait: QAWaitCondition,
        in preview: DevicePreviewView,
        completion: @escaping (Result<Any?, Error>) -> Void
    ) {
        guard wait.selector != nil || wait.javascript != nil else {
            completion(.success(true))
            return
        }
        let timeout = max(0, wait.timeoutMilliseconds ?? 10_000) / 1_000
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let interval = max(10, wait.pollIntervalMilliseconds ?? 100) / 1_000
        let expression = waitExpression(wait)

        func check() {
            guard !isFinished else { return }
            preview.evaluateJavaScript(expression) { [weak self] result in
                guard let self, !self.isFinished else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let value):
                    if value as? Bool == true {
                        completion(.success(true))
                    } else if ProcessInfo.processInfo.systemUptime >= deadline {
                        completion(.failure(QAPlaybackError.waitTimedOut(self.waitDescription(wait))))
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                            guard !self.isFinished else { return }
                            check()
                        }
                    }
                }
            }
        }
        check()
    }

    private func waitExpression(_ wait: QAWaitCondition) -> String {
        let selector: String
        if let value = wait.selector {
            selector = "document.querySelector(\(Self.quotedJavaScript(value))) !== null"
        } else {
            selector = "true"
        }
        let javascript = wait.javascript.map { "Boolean((\($0)))" } ?? "true"
        return "(\(selector)) && (\(javascript))"
    }

    private func waitDescription(_ wait: QAWaitCondition) -> String {
        if let selector = wait.selector, let javascript = wait.javascript {
            return "selector \(selector) and JavaScript condition \(javascript)"
        }
        if let selector = wait.selector { return "selector \(selector)" }
        if let javascript = wait.javascript { return "JavaScript condition \(javascript)" }
        return "the requested delay"
    }

    private static func quotedJavaScript(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }

    private func finish(wasCancelled: Bool) {
        guard !isFinished else { return }
        isFinished = true
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        completion(ResultSummary(
            eventCount: replayedEventCount,
            checkpointCount: replayedCheckpointCount,
            errorMessages: errors,
            elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - startedUptime) * 1_000,
            wasCancelled: wasCancelled,
            timing: timingSummary
        ))
    }
}

extension QADeviceConfiguration {
    static func template(
        profile: DeviceProfile,
        landscape: Bool,
        showSafeArea: Bool,
        applySafeAreaToPage: Bool,
        networkShapingConfiguration: NetworkShapingConfiguration = .disabled,
        header: QALayerConfiguration,
        footer: QALayerConfiguration,
        left: QALayerConfiguration? = nil,
        right: QALayerConfiguration? = nil
    ) -> QADeviceConfiguration {
        let screen = CGSize(
            width: landscape ? profile.viewport.height : profile.viewport.width,
            height: landscape ? profile.viewport.width : profile.viewport.height
        )
        let activeHeaderHeight = header.enabled ? CGFloat(header.heightCSSPixels) : 0
        let activeFooterHeight = footer.enabled ? CGFloat(footer.heightCSSPixels) : 0
        let leftWidth = left?.enabled == true ? CGFloat(left?.reservedExtentCSSPixels ?? 0) : 0
        let rightWidth = right?.enabled == true ? CGFloat(right?.reservedExtentCSSPixels ?? 0) : 0
        let page = PreviewMetrics.contentSize(
            device: profile,
            landscape: landscape,
            headerHeight: activeHeaderHeight,
            footerHeight: activeFooterHeight,
            leftWidth: leftWidth,
            rightWidth: rightWidth
        )
        let orientedSafe = SafeAreaGeometry.oriented(
            profile.safeArea,
            landscape: landscape
        )
        let sideWidths = PreviewMetrics.sideLayerWidths(
            viewportWidth: screen.width,
            landscape: landscape,
            leftWidth: leftWidth,
            rightWidth: rightWidth
        )
        let exposedSafe = SafeAreaGeometry.pageInsets(
            profile.safeArea,
            landscape: landscape,
            safariChrome: profile.safariChrome,
            topReservedHeight: PreviewMetrics.headerReservedHeight(
                device: profile,
                landscape: landscape,
                headerHeight: activeHeaderHeight
            ),
            leftReservedWidth: sideWidths.left,
            rightReservedWidth: sideWidths.right
        )
        let topChrome = profile.safariChrome
            ? (landscape ? SafariChromeMetrics.landscapeTop : SafariChromeMetrics.portraitTop)
            : 0
        let bottomChrome = profile.safariChrome
            ? (landscape ? SafariChromeMetrics.landscapeBottom : SafariChromeMetrics.portraitBottom)
            : 0
        return QADeviceConfiguration(
            profile: profile,
            orientation: landscape ? "landscape" : "portrait",
            resolution: QAResolutionConfiguration(
                profilePortraitCSS: QASize(
                    width: profile.viewport.width,
                    height: profile.viewport.height
                ),
                orientedScreenCSS: QASize(screen),
                pageContentCSS: QASize(page),
                devicePixelRatio: profile.viewport.dpr,
                orientedScreenPhysicalPixels: QASize(
                    width: screen.width * profile.viewport.dpr,
                    height: screen.height * profile.viewport.dpr
                ),
                pageContentPhysicalPixels: QASize(
                    width: page.width * profile.viewport.dpr,
                    height: page.height * profile.viewport.dpr
                )
            ),
            safeArea: QASafeAreaConfiguration(
                configuredPortrait: profile.safeArea,
                orientedDevice: orientedSafe,
                exposedToPage: exposedSafe,
                guideVisible: showSafeArea,
                forcedIntoPageLayout: applySafeAreaToPage,
                implementation: applySafeAreaToPage
                    ? (ProcessInfo.processInfo.isOperatingSystemAtLeast(
                        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
                    ) ? "native WebKit obscuredContentInsets" : "CSS padding fallback")
                    : "CSS env variables only"
            ),
            safari: QASafariConfiguration(
                enabled: profile.safariChrome,
                simulatedBrowser: profile.safariChrome ? "iOS Safari interface" : "none",
                renderingEngine: "Apple WebKit (WKWebView)",
                userAgent: profile.userAgent,
                topChromeCSSPixels: topChrome,
                bottomChromeCSSPixels: bottomChrome
            ),
            network: networkShapingConfiguration.normalized,
            header: header,
            footer: footer,
            left: left,
            right: right
        )
    }

    static func capture(
        preview: DevicePreviewView,
        header: QALayerConfiguration,
        footer: QALayerConfiguration,
        left: QALayerConfiguration? = nil,
        right: QALayerConfiguration? = nil
    ) -> QADeviceConfiguration {
        let device = preview.profile
        let screen = preview.logicalViewportSize
        let page = preview.contentViewportSize
        let orientedSafe = SafeAreaGeometry.oriented(preview.safeArea, landscape: preview.landscape)
        let activeHeaderHeight = preview.headerHTML == nil ? 0 : preview.headerHeight
        let sideWidths = PreviewMetrics.sideLayerWidths(
            viewportWidth: screen.width,
            landscape: preview.landscape,
            leftWidth: preview.leftHTML == nil ? 0 : preview.leftWidth,
            rightWidth: preview.rightHTML == nil ? 0 : preview.rightWidth
        )
        let exposedSafe = SafeAreaGeometry.pageInsets(
            preview.safeArea,
            landscape: preview.landscape,
            safariChrome: device.safariChrome,
            topReservedHeight: PreviewMetrics.headerReservedHeight(
                device: device,
                landscape: preview.landscape,
                headerHeight: activeHeaderHeight
            ),
            leftReservedWidth: sideWidths.left,
            rightReservedWidth: sideWidths.right
        )
        let topChrome = device.safariChrome
            ? (preview.landscape ? SafariChromeMetrics.landscapeTop : SafariChromeMetrics.portraitTop)
            : 0
        let bottomChrome = device.safariChrome
            ? (preview.landscape ? SafariChromeMetrics.landscapeBottom : SafariChromeMetrics.portraitBottom)
            : 0
        return QADeviceConfiguration(
            profile: device,
            orientation: preview.landscape ? "landscape" : "portrait",
            resolution: QAResolutionConfiguration(
                profilePortraitCSS: QASize(width: device.viewport.width, height: device.viewport.height),
                orientedScreenCSS: QASize(screen),
                pageContentCSS: QASize(page),
                devicePixelRatio: device.viewport.dpr,
                orientedScreenPhysicalPixels: QASize(
                    width: screen.width * device.viewport.dpr,
                    height: screen.height * device.viewport.dpr
                ),
                pageContentPhysicalPixels: QASize(
                    width: page.width * device.viewport.dpr,
                    height: page.height * device.viewport.dpr
                )
            ),
            safeArea: QASafeAreaConfiguration(
                configuredPortrait: preview.safeArea,
                orientedDevice: orientedSafe,
                exposedToPage: exposedSafe,
                guideVisible: preview.showSafeArea,
                forcedIntoPageLayout: preview.applySafeAreaToPage,
                implementation: preview.applySafeAreaToPage
                    ? (ProcessInfo.processInfo.isOperatingSystemAtLeast(
                        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
                    ) ? "native WebKit obscuredContentInsets" : "CSS padding fallback")
                    : "CSS env variables only"
            ),
            safari: QASafariConfiguration(
                enabled: device.safariChrome,
                simulatedBrowser: device.safariChrome ? "iOS Safari interface" : "none",
                renderingEngine: "Apple WebKit (WKWebView)",
                userAgent: device.userAgent,
                topChromeCSSPixels: topChrome,
                bottomChromeCSSPixels: bottomChrome
            ),
            network: preview.networkShapingConfiguration,
            header: header,
            footer: footer,
            left: left,
            right: right
        )
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func double(_ key: String) -> Double { optionalDouble(key) ?? 0 }
    func optionalDouble(_ key: String) -> Double? {
        if let value = self[key] as? NSNumber { return value.doubleValue }
        return self[key] as? Double
    }
    func int(_ key: String) -> Int { optionalInt(key) ?? 0 }
    func optionalInt(_ key: String) -> Int? {
        if let value = self[key] as? NSNumber { return value.intValue }
        return self[key] as? Int
    }
    func bool(_ key: String) -> Bool { optionalBool(key) ?? false }
    func optionalBool(_ key: String) -> Bool? {
        if let value = self[key] as? NSNumber { return value.boolValue }
        return self[key] as? Bool
    }
}
