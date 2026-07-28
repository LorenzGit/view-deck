import AppKit
import AVFoundation
import CoreVideo
import Darwin
import Foundation

public enum ViewDeckCommand {
    public static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let status = run(arguments: arguments)
        fflush(stdout)
        fflush(stderr)
        exit(status)
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            let invocation = try CLIInvocation.parse(arguments)
            switch invocation.operation {
            case .help:
                print(CLIHelp.text)
                return 0
            case .version:
                print(AppInfo.version)
                return 0
            case .devices:
                try printDevices(json: invocation.json)
                return 0
            case .capabilities:
                try printCapabilities(json: invocation.json)
                return 0
            case .capture, .inspect, .record:
                return runPreview(invocation)
            case .qaReplay:
                return runQAReplay(invocation)
            case .qaTemplate:
                return try writeQATemplate(invocation)
            }
        } catch {
            writeError(error.localizedDescription)
            writeError("Run `viewdeck help` for usage.")
            return 2
        }
    }

    private static func runPreview(_ invocation: CLIInvocation) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()

        var result: Result<[String: Any], Error>?
        var retainedSession: CLIPreviewSession?
        let session = CLIPreviewSession(invocation: invocation) { completion in
            result = completion
        }
        retainedSession = session
        session.start()

        while result == nil {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        }
        withExtendedLifetime(retainedSession) {}

        switch result! {
        case .success(let report):
            if invocation.json || invocation.operation == .inspect {
                if let encoded = try? CLIJSON.data(report, pretty: true),
                   let output = String(data: encoded, encoding: .utf8) {
                    print(output)
                }
            } else {
                let artifacts = report["artifacts"] as? [String: Any] ?? [:]
                if let screenshot = artifacts["screenshot"] as? String {
                    print("Screenshot: \(screenshot)")
                }
                if let video = artifacts["video"] as? String {
                    print("Video: \(video)")
                }
                if let reportPath = artifacts["report"] as? String {
                    print("Report: \(reportPath)")
                }
            }
            let summary = report["summary"] as? [String: Any]
            let shouldFail = summary?["failedPolicy"] as? Bool ?? false
            return shouldFail ? 1 : 0
        case .failure(let error):
            writeError(error.localizedDescription)
            return 1
        }
    }

    private static func runQAReplay(_ invocation: CLIInvocation) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()

        var result: Result<[String: Any], Error>?
        var retainedSession: CLIQAReplaySession?
        let session = CLIQAReplaySession(invocation: invocation) { completion in
            result = completion
        }
        retainedSession = session
        session.start()

        while result == nil {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        }
        withExtendedLifetime(retainedSession) {}

        switch result! {
        case .success(let report):
            if invocation.json {
                if let encoded = try? CLIJSON.data(report, pretty: true),
                   let output = String(data: encoded, encoding: .utf8) {
                    print(output)
                }
            } else {
                let artifacts = report["artifacts"] as? [String: Any] ?? [:]
                if let video = artifacts["video"] as? String { print("Video: \(video)") }
                if let screenshot = artifacts["screenshot"] as? String { print("Screenshot: \(screenshot)") }
                if let checkpoints = artifacts["checkpointDirectory"] as? String {
                    print("Checkpoints: \(checkpoints)")
                }
                if let reportPath = artifacts["report"] as? String { print("Report: \(reportPath)") }
            }
            let ok = report["ok"] as? Bool ?? false
            return ok ? 0 : 1
        case .failure(let error):
            writeError(error.localizedDescription)
            return 1
        }
    }

    private static func writeQATemplate(_ invocation: CLIInvocation) throws -> Int32 {
        let manager = FileManager.default
        let devices = BuiltinDevices.all + DeviceStore.load()
        guard let device = devices.first(where: { $0.id == invocation.deviceID }) else {
            throw CLIError.unknownDevice(invocation.deviceID)
        }
        guard let output = invocation.scenarioOutput else {
            throw CLIError.invalidArgument("qa template requires --output <scenario.viewdeck.json>.")
        }
        if manager.fileExists(atPath: output.path), !invocation.overwrite {
            throw CLIError.outputExists(output.path)
        }
        if let file = invocation.localFile, !manager.fileExists(atPath: file.path) {
            throw CLIError.missingFile(file.path)
        }
        if let project = invocation.project {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: project.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CLIError.missingDirectory(project.path)
            }
        }
        for file in [
            invocation.headerFile,
            invocation.footerFile,
            invocation.leftFile,
            invocation.rightFile
        ].compactMap({ $0 }) {
            guard manager.fileExists(atPath: file.path) else {
                throw CLIError.missingFile(file.path)
            }
        }
        try manager.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let headerHTML = try invocation.headerFile.map {
            try String(contentsOf: $0, encoding: .utf8)
        }
        let footerHTML = try invocation.footerFile.map {
            try String(contentsOf: $0, encoding: .utf8)
        }
        let leftHTML = try invocation.leftFile.map {
            try String(contentsOf: $0, encoding: .utf8)
        }
        let rightHTML = try invocation.rightFile.map {
            try String(contentsOf: $0, encoding: .utf8)
        }
        let header = QALayerConfiguration(
            kind: .header,
            html: headerHTML,
            height: invocation.headerHeight,
            sourcePath: invocation.headerFile?.path,
            baseURL: invocation.headerFile?.deletingLastPathComponent()
        )
        let footer = QALayerConfiguration(
            kind: .footer,
            html: footerHTML,
            height: invocation.footerHeight,
            sourcePath: invocation.footerFile?.path,
            baseURL: invocation.footerFile?.deletingLastPathComponent()
        )
        let left = QALayerConfiguration(
            kind: .left,
            html: leftHTML,
            height: invocation.leftWidth,
            sourcePath: invocation.leftFile?.path,
            baseURL: invocation.leftFile?.deletingLastPathComponent()
        )
        let right = QALayerConfiguration(
            kind: .right,
            html: rightHTML,
            height: invocation.rightWidth,
            sourcePath: invocation.rightFile?.path,
            baseURL: invocation.rightFile?.deletingLastPathComponent()
        )
        let configuration = QADeviceConfiguration.template(
            profile: device,
            landscape: invocation.landscape,
            showSafeArea: invocation.showSafeArea,
            applySafeAreaToPage: invocation.applySafeArea,
            header: header,
            footer: footer,
            left: left,
            right: right
        )
        let source = try qaTemplateSource(invocation)
        let now = Date()
        let scenario = QAScenario(
            schemaVersion: 1,
            id: UUID().uuidString,
            name: invocation.scenarioName
                ?? output.deletingPathExtension().lastPathComponent,
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
            environmentAtStart: nil,
            environmentAtEnd: nil,
            auditAtEnd: nil,
            timing: QATiming(
                clock: "original authoring milliseconds; replay may derive an effective smart timeline",
                recordedAt: now,
                finishedAt: now,
                durationMilliseconds: 0,
                eventCount: 0,
                gestureCount: 0,
                checkpointCount: 0
            ),
            events: [],
            gestures: [],
            checkpoints: [],
            artifacts: [],
            notes: [
                "AI authoring template generated by ViewDeck. Copy and adapt entries from authoring.eventExamples."
            ],
            authoring: QAJSONValue(any: qaAuthoringMetadata(configuration: configuration))
        )
        try QAScenarioFiles.save(scenario, to: output)

        if invocation.json {
            let report: [String: Any] = [
                "schemaVersion": 1,
                "ok": true,
                "command": "qa template",
                "output": output.path,
                "device": device.id,
                "eventCount": 0
            ]
            print(String(data: try CLIJSON.data(report, pretty: true), encoding: .utf8)!)
        } else {
            print("Scenario template: \(output.path)")
        }
        return 0
    }

    private static func qaTemplateSource(
        _ invocation: CLIInvocation
    ) throws -> QASourceConfiguration {
        if let file = invocation.localFile {
            return QASourceConfiguration(
                requestedURL: file.absoluteString,
                finalURL: file.absoluteString,
                pageTitle: nil,
                projectPath: nil,
                launchMode: "staticHTML",
                npmScript: nil,
                customCommand: nil,
                staticHTMLPath: file.path
            )
        }
        if let project = invocation.project {
            return QASourceConfiguration(
                requestedURL: nil,
                finalURL: nil,
                pageTitle: nil,
                projectPath: project.path,
                launchMode: invocation.serverCommand == nil ? "npmScript" : "customCommand",
                npmScript: invocation.serverCommand == nil ? invocation.npmScript ?? "dev" : nil,
                customCommand: invocation.serverCommand,
                staticHTMLPath: nil
            )
        }
        guard let rawURL = invocation.sourceURL,
              let baseURL = PreviewNavigationPolicy.normalizedWebURL(from: rawURL) else {
            throw CLIError.invalidArgument("Invalid URL `\(invocation.sourceURL ?? "")`.")
        }
        let url = CLIPath.appending(route: invocation.route, to: baseURL).absoluteString
        return QASourceConfiguration(
            requestedURL: url,
            finalURL: url,
            pageTitle: nil,
            projectPath: nil,
            launchMode: "url",
            npmScript: nil,
            customCommand: nil,
            staticHTMLPath: nil
        )
    }

    private static func qaAuthoringMetadata(
        configuration: QADeviceConfiguration
    ) -> [String: Any] {
        let viewport = configuration.resolution.pageContentCSS
        let viewportValue: [String: Any] = [
            "width": viewport.width,
            "height": viewport.height
        ]
        let centerX = viewport.width / 2
        let centerY = viewport.height / 2
        let pointerType = configuration.profile.mobile ? "touch" : "mouse"
        func pointer(_ buttons: Int) -> [String: Any] {
            [
                "clientX": centerX,
                "clientY": centerY,
                "normalizedX": 0.5,
                "normalizedY": 0.5,
                "pageX": centerX,
                "pageY": centerY,
                "screenX": centerX,
                "screenY": centerY,
                "movementX": 0,
                "movementY": 0,
                "button": 0,
                "buttons": buttons,
                "detail": 1,
                "pointerID": 1,
                "pointerType": pointerType,
                "isPrimary": true,
                "pressure": buttons == 0 ? 0 : 0.5,
                "tangentialPressure": 0,
                "tiltX": 0,
                "tiltY": 0,
                "twist": 0,
                "width": 1,
                "height": 1
            ]
        }
        let keyboard: [String: Any] = [
            "key": "ArrowRight",
            "code": "ArrowRight",
            "location": 0,
            "repeatKey": false,
            "isComposing": false,
            "keyCode": 39,
            "charCode": 0,
            "alt": false,
            "control": false,
            "meta": false,
            "shift": false
        ]
        return [
            "purpose": "Copy and adapt these examples into the top-level events array.",
            "rules": [
                "Use stable, unique event ids.",
                "Keep events sorted by atMilliseconds.",
                "Set intervalSincePreviousMilliseconds to the difference from the previous event.",
                "Use normalized pointer coordinates for PixiJS, Three.js, and canvas tests.",
                "Use wait events for real readiness requirements instead of encoding AI processing time."
            ],
            "smartTiming": [
                "command": "viewdeck qa replay <scenario> --speed smart",
                "preservedGapLimitMilliseconds":
                    QAPlaybackTimingPlanner.preservedGapLimitMilliseconds,
                "compressedIdleGapMilliseconds":
                    QAPlaybackTimingPlanner.compressedIdleGapMilliseconds,
                "preserves": [
                    "pointer and mouse down-to-up sequences",
                    "keyboard down-to-up holds",
                    "gaps at or below the preserved limit",
                    "explicit wait events"
                ]
            ],
            "eventExamples": [
                "click": [
                    [
                        "id": "click-down",
                        "type": "pointerdown",
                        "atMilliseconds": 250,
                        "intervalSincePreviousMilliseconds": 250,
                        "viewportCSS": viewportValue,
                        "pointer": pointer(1),
                        "target": ["selector": "#start", "isCanvas": false]
                    ],
                    [
                        "id": "click-up",
                        "type": "pointerup",
                        "atMilliseconds": 330,
                        "intervalSincePreviousMilliseconds": 80,
                        "viewportCSS": viewportValue,
                        "pointer": pointer(0),
                        "target": ["selector": "#start", "isCanvas": false]
                    ],
                    [
                        "id": "click",
                        "type": "click",
                        "atMilliseconds": 340,
                        "intervalSincePreviousMilliseconds": 10,
                        "viewportCSS": viewportValue,
                        "pointer": pointer(0),
                        "target": ["selector": "#start", "isCanvas": false]
                    ]
                ],
                "keyPress": [
                    [
                        "id": "key-down",
                        "type": "keydown",
                        "atMilliseconds": 1_000,
                        "intervalSincePreviousMilliseconds": 670,
                        "viewportCSS": viewportValue,
                        "keyboard": keyboard
                    ],
                    [
                        "id": "key-up",
                        "type": "keyup",
                        "atMilliseconds": 1_100,
                        "intervalSincePreviousMilliseconds": 100,
                        "viewportCSS": viewportValue,
                        "keyboard": keyboard
                    ]
                ],
                "waitForSelector": [
                    "id": "wait-for-game",
                    "type": "wait",
                    "atMilliseconds": 1_350,
                    "intervalSincePreviousMilliseconds": 250,
                    "viewportCSS": viewportValue,
                    "wait": [
                        "selector": "canvas",
                        "timeoutMilliseconds": 10_000,
                        "pollIntervalMilliseconds": 100
                    ]
                ],
                "waitForJavaScript": [
                    "id": "wait-for-ready-state",
                    "type": "wait",
                    "atMilliseconds": 1_600,
                    "intervalSincePreviousMilliseconds": 250,
                    "viewportCSS": viewportValue,
                    "wait": [
                        "javascript": "window.gameReady === true",
                        "timeoutMilliseconds": 10_000,
                        "pollIntervalMilliseconds": 100
                    ]
                ],
                "fixedDelay": [
                    "id": "wait-for-animation",
                    "type": "wait",
                    "atMilliseconds": 1_850,
                    "intervalSincePreviousMilliseconds": 250,
                    "viewportCSS": viewportValue,
                    "wait": ["delayMilliseconds": 500]
                ]
            ]
        ]
    }

    private static func printDevices(json: Bool) throws {
        let custom = DeviceStore.load()
        let devices = BuiltinDevices.all + custom
        let values = devices.map { device -> [String: Any] in
            [
                "id": device.id,
                "name": device.name,
                "platform": device.platform.rawValue,
                "builtin": device.builtin,
                "viewport": [
                    "width": device.viewport.width,
                    "height": device.viewport.height,
                    "dpr": device.viewport.dpr
                ],
                "safeArea": [
                    "top": device.safeArea.top,
                    "right": device.safeArea.right,
                    "bottom": device.safeArea.bottom,
                    "left": device.safeArea.left
                ],
                "safariChrome": device.safariChrome,
                "homeIndicator": device.homeIndicator
            ]
        }
        if json {
            let output: [String: Any] = [
                "schemaVersion": 1,
                "devices": values
            ]
            print(String(data: try CLIJSON.data(output, pretty: true), encoding: .utf8)!)
        } else {
            for device in devices {
                let viewport = "\(Int(device.viewport.width))x\(Int(device.viewport.height))"
                let source = device.builtin ? "builtin" : "custom"
                print("\(device.id)\t\(viewport) @ \(device.viewport.dpr)x\t\(source)\t\(device.name)")
            }
        }
    }

    private static func printCapabilities(json: Bool) throws {
        let capabilities: [String: Any] = [
            "schemaVersion": 1,
            "commands": [
                "devices", "capture", "inspect", "record", "qa replay", "qa template", "capabilities"
            ],
            "sources": ["url", "localFile", "npmScript", "customCommand"],
            "readiness": ["load", "cssSelector", "javaScript", "prepareJavaScript", "delay"],
            "artifacts": ["png", "mp4", "json"],
            "qa": [
                "schemaVersion": 1,
                "recording": ["pointer", "mouse", "keyboard", "form", "checkpoints", "video"],
                "replaySpeeds": ["0.5x", "1x", "2x", "4x", "smart", "maximum"],
                "semanticWaits": ["delay", "cssSelector", "javaScript"],
                "coordinateSystems": ["absoluteCSSPixels", "normalizedViewport"],
                "configuration": [
                    "deviceProfile", "orientation", "CSSResolution", "physicalResolution",
                    "DPR", "safeArea", "SafariChrome", "header", "footer",
                    "landscapeLeftRail", "landscapeRightRail", "source"
                ]
            ],
            "captureScales": ["0.5...3", "deviceDPR"],
            "auditChecks": [
                "horizontalOverflow",
                "elementsOutsideViewport",
                "interactiveSafeAreaOverlap",
                "interactiveOutsideViewport",
                "consoleMessages",
                "pageErrors"
            ]
        ]
        if json {
            print(String(data: try CLIJSON.data(capabilities, pretty: true), encoding: .utf8)!)
        } else {
            print("ViewDeck CLI supports deterministic WKWebView screenshots, MP4 recording, page audits, and local dev-server lifecycle management.")
        }
    }

    fileprivate static func writeError(_ value: String) {
        FileHandle.standardError.write(Data(("viewdeck: \(value)\n").utf8))
    }
}

struct CLIInvocation {
    enum Operation: String {
        case help
        case version
        case devices
        case capabilities
        case capture
        case inspect
        case record
        case qaReplay
        case qaTemplate
    }

    var operation: Operation
    var json = false
    var sourceURL: String?
    var localFile: URL?
    var project: URL?
    var npmScript: String?
    var serverCommand: String?
    var route: String?
    var deviceID = "iphone-17-pro-max"
    var landscape = false
    var showSafeArea = false
    var applySafeArea = false
    var headerFile: URL?
    var headerHeight: CGFloat = 48
    var footerFile: URL?
    var footerHeight: CGFloat = 56
    var leftFile: URL?
    var leftWidth: CGFloat = 118
    var rightFile: URL?
    var rightWidth: CGFloat = 118
    var waitSelector: String?
    var waitJavaScript: String?
    var prepareJavaScript: String?
    var delay: TimeInterval = 0.5
    var timeout: TimeInterval = 30
    var screenshotOutput: URL?
    var reportOutput: URL?
    var videoOutput: URL?
    var captureScale: CGFloat?
    var videoScale: CGFloat = 1
    var videoDuration: TimeInterval = 5
    var videoFPS = 30
    var overwrite = false
    var failOnPageError = false
    var failOnIssues = false
    var scenarioInput: URL?
    var scenarioOutput: URL?
    var scenarioName: String?
    var playbackSpeed: Double = 1
    var smartPlayback = false
    var artifactDirectory: URL?

    static func parse(_ arguments: [String]) throws -> CLIInvocation {
        guard let command = arguments.first else {
            return CLIInvocation(operation: .help)
        }
        if ["help", "--help", "-h"].contains(command) {
            return CLIInvocation(operation: .help)
        }
        if ["version", "--version"].contains(command) {
            return CLIInvocation(operation: .version)
        }

        let operation: Operation
        var firstOptionIndex = 1
        switch command {
        case "devices": operation = .devices
        case "capabilities": operation = .capabilities
        case "capture": operation = .capture
        case "inspect", "audit": operation = .inspect
        case "record": operation = .record
        case "qa":
            guard arguments.indices.contains(1) else {
                throw CLIError.invalidArgument(
                    "Use `viewdeck qa replay <scenario.viewdeck.json>` or `viewdeck qa template`."
                )
            }
            switch arguments[1] {
            case "replay": operation = .qaReplay
            case "template": operation = .qaTemplate
            default:
                throw CLIError.invalidArgument(
                    "Use `viewdeck qa replay <scenario.viewdeck.json>` or `viewdeck qa template`."
                )
            }
            firstOptionIndex = 2
        default: throw CLIError.invalidArgument("Unknown command `\(command)`.")
        }

        var value = CLIInvocation(operation: operation)
        var index = firstOptionIndex
        if operation == .devices, arguments.indices.contains(index), arguments[index] == "list" {
            index += 1
        }

        func requiredValue(for flag: String) throws -> String {
            index += 1
            guard arguments.indices.contains(index) else {
                throw CLIError.invalidArgument("Missing value for \(flag).")
            }
            return arguments[index]
        }

        while arguments.indices.contains(index) {
            let argument = arguments[index]
            switch argument {
            case "--json": value.json = true
            case "--url": value.sourceURL = try requiredValue(for: argument)
            case "--file":
                value.localFile = CLIPath.url(try requiredValue(for: argument))
            case "--project":
                value.project = CLIPath.url(try requiredValue(for: argument), directory: true)
            case "--npm-script":
                value.npmScript = try requiredValue(for: argument)
            case "--command":
                value.serverCommand = try requiredValue(for: argument)
            case "--path":
                value.route = try requiredValue(for: argument)
            case "--device":
                value.deviceID = try requiredValue(for: argument)
            case "--orientation":
                let orientation = try requiredValue(for: argument)
                guard ["portrait", "landscape"].contains(orientation) else {
                    throw CLIError.invalidArgument("--orientation must be `portrait` or `landscape`.")
                }
                value.landscape = orientation == "landscape"
            case "--show-safe-area": value.showSafeArea = true
            case "--apply-safe-area": value.applySafeArea = true
            case "--header":
                value.headerFile = CLIPath.url(try requiredValue(for: argument))
            case "--header-height":
                value.headerHeight = try positiveCGFloat(try requiredValue(for: argument), flag: argument)
            case "--footer":
                value.footerFile = CLIPath.url(try requiredValue(for: argument))
            case "--footer-height":
                value.footerHeight = try positiveCGFloat(try requiredValue(for: argument), flag: argument)
            case "--left":
                value.leftFile = CLIPath.url(try requiredValue(for: argument))
            case "--left-width":
                value.leftWidth = try positiveCGFloat(try requiredValue(for: argument), flag: argument)
            case "--right":
                value.rightFile = CLIPath.url(try requiredValue(for: argument))
            case "--right-width":
                value.rightWidth = try positiveCGFloat(try requiredValue(for: argument), flag: argument)
            case "--wait-for":
                value.waitSelector = try requiredValue(for: argument)
            case "--wait-js":
                value.waitJavaScript = try requiredValue(for: argument)
            case "--prepare-js":
                value.prepareJavaScript = try requiredValue(for: argument)
            case "--delay":
                value.delay = try nonnegativeDouble(try requiredValue(for: argument), flag: argument)
            case "--timeout":
                value.timeout = try positiveDouble(try requiredValue(for: argument), flag: argument)
            case "--output":
                let output = CLIPath.url(try requiredValue(for: argument))
                if operation == .record {
                    value.videoOutput = output
                } else if operation == .qaTemplate {
                    value.scenarioOutput = output
                } else {
                    value.screenshotOutput = output
                }
            case "--name":
                value.scenarioName = try requiredValue(for: argument)
            case "--screenshot":
                value.screenshotOutput = CLIPath.url(try requiredValue(for: argument))
            case "--video":
                value.videoOutput = CLIPath.url(try requiredValue(for: argument))
            case "--report":
                value.reportOutput = CLIPath.url(try requiredValue(for: argument))
            case "--scale":
                value.captureScale = try boundedScale(try requiredValue(for: argument), flag: argument)
            case "--video-scale":
                value.videoScale = try boundedScale(try requiredValue(for: argument), flag: argument)
            case "--duration":
                value.videoDuration = try positiveDouble(try requiredValue(for: argument), flag: argument)
            case "--fps":
                guard let fps = Int(try requiredValue(for: argument)), (1...30).contains(fps) else {
                    throw CLIError.invalidArgument("--fps must be between 1 and 30.")
                }
                value.videoFPS = fps
            case "--overwrite": value.overwrite = true
            case "--fail-on-page-error": value.failOnPageError = true
            case "--fail-on-issues": value.failOnIssues = true
            case "--speed":
                let speed = try requiredValue(for: argument)
                if speed == "smart" {
                    value.smartPlayback = true
                    value.playbackSpeed = 1
                } else if speed == "max" || speed == "maximum" {
                    value.smartPlayback = false
                    value.playbackSpeed = 0
                } else {
                    value.smartPlayback = false
                    value.playbackSpeed = try positiveDouble(speed, flag: argument)
                }
            case "--artifacts":
                value.artifactDirectory = CLIPath.url(try requiredValue(for: argument), directory: true)
            case "--help", "-h":
                return CLIInvocation(operation: .help)
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.invalidArgument("Unknown option `\(argument)`.")
                }
                if operation == .qaReplay {
                    guard value.scenarioInput == nil else {
                        throw CLIError.invalidArgument("Only one QA scenario file may be provided.")
                    }
                    value.scenarioInput = CLIPath.url(argument)
                    index += 1
                    continue
                }
                guard value.sourceURL == nil else {
                    throw CLIError.invalidArgument("Only one positional URL may be provided.")
                }
                value.sourceURL = argument
            }
            index += 1
        }

        if [.devices, .capabilities].contains(operation) { return value }
        try value.validate()
        return value
    }

    private mutating func validate() throws {
        if operation == .qaReplay {
            guard let scenarioInput else {
                throw CLIError.invalidArgument("qa replay requires a .viewdeck.json scenario file.")
            }
            guard scenarioInput.pathExtension.lowercased() == "json" else {
                throw CLIError.invalidArgument("The QA scenario must use the .json extension.")
            }
            try validateOutputs()
            return
        }
        if operation == .qaTemplate {
            guard let scenarioOutput else {
                throw CLIError.invalidArgument("qa template requires --output <scenario.viewdeck.json>.")
            }
            guard scenarioOutput.pathExtension.lowercased() == "json" else {
                throw CLIError.invalidArgument("The QA template output must use the .json extension.")
            }
        }
        let sourceCount = [sourceURL != nil, localFile != nil, project != nil].filter { $0 }.count
        guard sourceCount == 1 else {
            throw CLIError.invalidArgument("Provide exactly one source: a URL, --file, or --project.")
        }
        if serverCommand != nil && npmScript != nil {
            throw CLIError.invalidArgument("Use either --npm-script or --command, not both.")
        }
        if project == nil && (serverCommand != nil || npmScript != nil) {
            throw CLIError.invalidArgument("--npm-script and --command require --project.")
        }
        if project != nil && serverCommand == nil && npmScript == nil {
            npmScript = "dev"
        }
        switch operation {
        case .capture:
            guard screenshotOutput != nil else {
                throw CLIError.invalidArgument("capture requires --output <image.png>.")
            }
        case .record:
            guard videoOutput != nil else {
                throw CLIError.invalidArgument("record requires --output <video.mp4>.")
            }
        default: break
        }
        try validateOutputs()
    }

    private func validateOutputs() throws {
        if let screenshotOutput,
           screenshotOutput.pathExtension.lowercased() != "png" {
            throw CLIError.invalidArgument("Screenshot output must use the .png extension.")
        }
        if let videoOutput,
           videoOutput.pathExtension.lowercased() != "mp4" {
            throw CLIError.invalidArgument("Video output must use the .mp4 extension.")
        }
        if let reportOutput,
           reportOutput.pathExtension.lowercased() != "json" {
            throw CLIError.invalidArgument("Report output must use the .json extension.")
        }
        if let scenarioOutput,
           scenarioOutput.pathExtension.lowercased() != "json" {
            throw CLIError.invalidArgument("QA scenario output must use the .json extension.")
        }
    }

    private static func positiveDouble(_ value: String, flag: String) throws -> Double {
        guard let result = Double(value), result > 0 else {
            throw CLIError.invalidArgument("\(flag) requires a positive number.")
        }
        return result
    }

    private static func nonnegativeDouble(_ value: String, flag: String) throws -> Double {
        guard let result = Double(value), result >= 0 else {
            throw CLIError.invalidArgument("\(flag) requires a nonnegative number.")
        }
        return result
    }

    private static func positiveCGFloat(_ value: String, flag: String) throws -> CGFloat {
        CGFloat(try positiveDouble(value, flag: flag))
    }

    private static func boundedScale(_ value: String, flag: String) throws -> CGFloat {
        let result = try positiveCGFloat(value, flag: flag)
        guard (0.5...3).contains(result) else {
            throw CLIError.invalidArgument("\(flag) must be between 0.5 and 3.")
        }
        return result
    }
}

private final class CLIPreviewSession: NSObject, DevicePreviewDelegate, DevServerControllerDelegate {
    private let invocation: CLIInvocation
    private let completion: (Result<[String: Any], Error>) -> Void
    private let server = DevServerController()
    private let startedAt = Date()
    private var preview: DevicePreviewView!
    private var window: NSWindow?
    private var device: DeviceProfile!
    private var title: String?
    private var finalURL: URL?
    private var serverURL: URL?
    private var serverLog: [[String: Any]] = []
    private var timeoutWorkItem: DispatchWorkItem?
    private var pipelineStarted = false
    private var finished = false
    private var videoRecorder: PreviewVideoRecorder?
    private var artifactPaths: [String: String] = [:]

    init(
        invocation: CLIInvocation,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        self.invocation = invocation
        self.completion = completion
    }

    func start() {
        do {
            let devices = BuiltinDevices.all + DeviceStore.load()
            guard let selected = devices.first(where: { $0.id == invocation.deviceID }) else {
                throw CLIError.unknownDevice(invocation.deviceID)
            }
            device = selected
            try validateInputs()
            try preparePreview()
            beginTimeout()
            try loadSource()
        } catch {
            finish(.failure(error))
        }
    }

    private func validateInputs() throws {
        let manager = FileManager.default
        if let file = invocation.localFile, !manager.fileExists(atPath: file.path) {
            throw CLIError.missingFile(file.path)
        }
        if let project = invocation.project {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: project.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CLIError.missingDirectory(project.path)
            }
        }
        for file in [
            invocation.headerFile,
            invocation.footerFile,
            invocation.leftFile,
            invocation.rightFile
        ].compactMap({ $0 }) {
            guard manager.fileExists(atPath: file.path) else {
                throw CLIError.missingFile(file.path)
            }
        }
        for output in [
            invocation.screenshotOutput,
            invocation.videoOutput,
            invocation.reportOutput
        ].compactMap({ $0 }) {
            if manager.fileExists(atPath: output.path), !invocation.overwrite {
                throw CLIError.outputExists(output.path)
            }
            try manager.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
    }

    private func preparePreview() throws {
        preview = DevicePreviewView(profile: device)
        preview.delegate = self
        preview.landscape = invocation.landscape
        preview.showSafeArea = invocation.showSafeArea
        preview.applySafeAreaToPage = invocation.applySafeArea
        if let header = invocation.headerFile {
            preview.headerHTML = try String(contentsOf: header, encoding: .utf8)
            preview.headerBaseURL = header.deletingLastPathComponent()
            preview.headerHeight = invocation.headerHeight
        }
        if let footer = invocation.footerFile {
            preview.footerHTML = try String(contentsOf: footer, encoding: .utf8)
            preview.footerBaseURL = footer.deletingLastPathComponent()
            preview.footerHeight = invocation.footerHeight
        }
        if let left = invocation.leftFile {
            preview.leftHTML = try String(contentsOf: left, encoding: .utf8)
            preview.leftBaseURL = left.deletingLastPathComponent()
            preview.leftWidth = invocation.leftWidth
        }
        if let right = invocation.rightFile {
            preview.rightHTML = try String(contentsOf: right, encoding: .utf8)
            preview.rightBaseURL = right.deletingLastPathComponent()
            preview.rightWidth = invocation.rightWidth
        }

        let size = preview.logicalSize
        let frame = CGRect(origin: .zero, size: size)
        preview.frame = frame
        preview.bounds = frame
        preview.autoresizingMask = [.width, .height]
        let hiddenWindow = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hiddenWindow.contentView = preview
        if let visibleFrame = NSScreen.main?.visibleFrame {
            hiddenWindow.setFrameOrigin(CGPoint(
                x: visibleFrame.maxX - size.width,
                y: visibleFrame.minY
            ))
        }
        hiddenWindow.ignoresMouseEvents = true
        hiddenWindow.hidesOnDeactivate = false
        hiddenWindow.collectionBehavior = [.stationary, .ignoresCycle]
        hiddenWindow.orderFrontRegardless()
        window = hiddenWindow
        preview.layoutSubtreeIfNeeded()
    }

    private func loadSource() throws {
        server.delegate = self
        if let file = invocation.localFile {
            preview.loadLocalFile(file)
            return
        }
        if let rawURL = invocation.sourceURL {
            guard let url = PreviewNavigationPolicy.normalizedWebURL(from: rawURL) else {
                throw CLIError.invalidArgument("Invalid URL `\(rawURL)`.")
            }
            preview.load(CLIPath.appending(route: invocation.route, to: url).absoluteString)
            return
        }
        guard let project = invocation.project else {
            throw CLIError.invalidArgument("No preview source was provided.")
        }
        preview.prepareForLocalServerLaunch()
        if let command = invocation.serverCommand {
            try server.startCommand(folder: project, command: command)
        } else {
            try server.start(folder: project, script: invocation.npmScript ?? "dev")
        }
    }

    private func beginTimeout() {
        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure(CLIError.timeout(self?.invocation.timeout ?? 0)))
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + invocation.timeout, execute: work)
    }

    func previewDidStartLoading() {}

    func previewDidFinishLoading(title: String?, url: URL?) {
        guard let url else { return }
        self.title = title
        finalURL = url
        guard !pipelineStarted else { return }
        waitUntilReady()
    }

    func previewDidFail(_ message: String) {
        finish(.failure(CLIError.navigation(message)))
    }

    func devServerStateChanged(_ state: DevServerState, url: URL?) {
        switch state {
        case .running:
            guard let url, serverURL != url else { return }
            serverURL = url
            let target = CLIPath.appending(route: invocation.route, to: url)
            preview.loadLocalServer(target.absoluteString, resetSiteData: true)
        case .failed:
            finish(.failure(CLIError.serverFailed))
        default:
            break
        }
    }

    func devServerDidOutput(_ line: String, isError: Bool) {
        serverLog.append([
            "stream": isError ? "stderr" : "stdout",
            "message": line
        ])
        if serverLog.count > 300 {
            serverLog.removeFirst(serverLog.count - 300)
        }
        ViewDeckCommand.writeError(line)
    }

    private func waitUntilReady() {
        if invocation.waitSelector == nil && invocation.waitJavaScript == nil {
            beginReadyPipeline()
            return
        }
        pollReadiness()
    }

    private func pollReadiness() {
        guard !finished, !pipelineStarted else { return }
        let selectorCondition: String
        if let selector = invocation.waitSelector {
            selectorCondition = "document.querySelector(\(CLIJSON.quoted(selector))) !== null"
        } else {
            selectorCondition = "true"
        }
        let javascriptCondition: String
        if let expression = invocation.waitJavaScript {
            javascriptCondition = "Boolean((\(expression)))"
        } else {
            javascriptCondition = "true"
        }
        preview.evaluateJavaScript("(\(selectorCondition)) && (\(javascriptCondition))") { [weak self] result in
            guard let self, !self.finished else { return }
            if case .success(let value) = result, value as? Bool == true {
                self.beginReadyPipeline()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.pollReadiness()
                }
            }
        }
    }

    private func beginReadyPipeline() {
        guard !pipelineStarted, !finished else { return }
        pipelineStarted = true
        let continueAfterPreparation = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.invocation.delay) { [weak self] in
                self?.generateArtifacts()
            }
        }
        guard let script = invocation.prepareJavaScript else {
            continueAfterPreparation()
            return
        }
        preview.evaluateJavaScript(script) { [weak self] result in
            switch result {
            case .success:
                continueAfterPreparation()
            case .failure(let error):
                self?.finish(.failure(CLIError.preparation(error.localizedDescription)))
            }
        }
    }

    private func generateArtifacts() {
        guard !finished else { return }
        if let videoURL = invocation.videoOutput {
            let recorder = PreviewVideoRecorder(
                outputURL: videoURL,
                duration: invocation.videoDuration,
                framesPerSecond: invocation.videoFPS,
                captureScale: invocation.videoScale,
                overwrite: invocation.overwrite
            )
            videoRecorder = recorder
            recorder.record(preview: preview) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error): self.finish(.failure(error))
                case .success:
                    self.artifactPaths["video"] = videoURL.path
                    self.captureStillIfNeeded()
                }
            }
        } else {
            captureStillIfNeeded()
        }
    }

    private func captureStillIfNeeded() {
        guard !finished else { return }
        guard let output = invocation.screenshotOutput else {
            inspectPage()
            return
        }
        preview.captureScreenshot(scale: invocation.captureScale) { [weak self] result in
            guard let self else { return }
            do {
                let image = try result.get()
                let data = try CLIImage.pngData(image)
                if self.invocation.overwrite, FileManager.default.fileExists(atPath: output.path) {
                    try FileManager.default.removeItem(at: output)
                }
                try data.write(to: output, options: .atomic)
                self.artifactPaths["screenshot"] = output.path
                self.inspectPage()
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func inspectPage() {
        guard !finished else { return }
        preview.captureAudit { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(.failure(error))
            case .success(let audit):
                do {
                    let report = try self.makeReport(audit: audit)
                    self.finish(.success(report))
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func makeReport(audit: [String: Any]) throws -> [String: Any] {
        let issues = audit["issues"] as? [[String: Any]] ?? []
        let pageErrors = audit["pageErrors"] as? [[String: Any]] ?? []
        let failedPolicy = (invocation.failOnIssues && !issues.isEmpty)
            || (invocation.failOnPageError && !pageErrors.isEmpty)
        let orientedSafe = SafeAreaGeometry.pageInsets(
            device.safeArea,
            landscape: invocation.landscape,
            safariChrome: device.safariChrome
        )
        let viewport = preview.logicalViewportSize
        let contentViewport = preview.contentViewportSize
        var artifacts: [String: Any] = artifactPaths
        if let reportURL = invocation.reportOutput {
            artifacts["report"] = reportURL.path
        }

        var source: [String: Any] = [:]
        if let value = invocation.sourceURL { source["requestedURL"] = value }
        if let value = invocation.localFile { source["localFile"] = value.path }
        if let value = invocation.project { source["project"] = value.path }
        if let value = invocation.npmScript { source["npmScript"] = value }
        if let value = invocation.serverCommand { source["command"] = value }
        if let value = serverURL { source["serverURL"] = value.absoluteString }
        if let value = finalURL { source["finalURL"] = value.absoluteString }
        source["title"] = (audit["title"] as? String) ?? title ?? ""

        var report: [String: Any] = [
            "schemaVersion": 1,
            "ok": true,
            "command": invocation.operation.rawValue,
            "source": source,
            "device": [
                "id": device.id,
                "name": device.name,
                "platform": device.platform.rawValue,
                "orientation": invocation.landscape ? "landscape" : "portrait",
                "viewport": [
                    "width": viewport.width,
                    "height": viewport.height,
                    "dpr": device.viewport.dpr,
                    "physicalWidth": viewport.width * device.viewport.dpr,
                    "physicalHeight": viewport.height * device.viewport.dpr
                ],
                "contentViewport": [
                    "width": contentViewport.width,
                    "height": contentViewport.height
                ],
                "safeArea": [
                    "top": orientedSafe.top,
                    "right": orientedSafe.right,
                    "bottom": orientedSafe.bottom,
                    "left": orientedSafe.left
                ],
                "safariChrome": device.safariChrome
            ],
            "audit": audit,
            "serverLog": serverLog,
            "artifacts": artifacts,
            "summary": [
                "issueCount": issues.count,
                "pageErrorCount": pageErrors.count,
                "consoleMessageCount": (audit["consoleMessages"] as? [Any])?.count ?? 0,
                "failedPolicy": failedPolicy
            ],
            "timing": [
                "startedAt": ISO8601DateFormatter().string(from: startedAt),
                "finishedAt": ISO8601DateFormatter().string(from: Date()),
                "durationMs": Int(Date().timeIntervalSince(startedAt) * 1_000)
            ]
        ]
        report = CLIJSON.removingInvalidNulls(report)
        if let reportURL = invocation.reportOutput {
            if invocation.overwrite, FileManager.default.fileExists(atPath: reportURL.path) {
                try FileManager.default.removeItem(at: reportURL)
            }
            try CLIJSON.data(report, pretty: true).write(to: reportURL, options: .atomic)
        }
        return report
    }

    private func finish(_ result: Result<[String: Any], Error>) {
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        server.stop()
        window?.orderOut(nil)
        window = nil
        completion(result)
    }
}

private final class CLIQAReplaySession: NSObject, DevicePreviewDelegate, DevServerControllerDelegate {
    private let invocation: CLIInvocation
    private let completion: (Result<[String: Any], Error>) -> Void
    private let server = DevServerController()
    private let startedAt = Date()
    private var scenario: QAScenario!
    private var preview: DevicePreviewView!
    private var window: NSWindow?
    private var serverLog: [[String: Any]] = []
    private var finalURL: URL?
    private var timeoutWorkItem: DispatchWorkItem?
    private var playback: QAPlaybackController?
    private var playbackSummary: QAPlaybackController.ResultSummary?
    private var videoRecorder: LivePreviewVideoRecorder?
    private var videoFinished = true
    private var checkpointPaths: [String] = []
    private var replayErrors: [String] = []
    private var pipelineStarted = false
    private var finalizing = false
    private var finished = false
    private var artifactPaths: [String: Any] = [:]

    init(
        invocation: CLIInvocation,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        self.invocation = invocation
        self.completion = completion
    }

    func start() {
        do {
            guard let scenarioURL = invocation.scenarioInput else {
                throw CLIError.invalidArgument("No QA scenario was provided.")
            }
            scenario = try QAScenarioFiles.load(scenarioURL)
            guard scenario.schemaVersion == 1 else {
                throw CLIError.invalidArgument("Unsupported QA scenario schema \(scenario.schemaVersion).")
            }
            try validateInputs()
            try preparePreview()
            beginTimeout()
            try loadSource()
        } catch {
            finish(.failure(error))
        }
    }

    private func validateInputs() throws {
        let manager = FileManager.default
        guard let scenarioURL = invocation.scenarioInput,
              manager.fileExists(atPath: scenarioURL.path) else {
            throw CLIError.missingFile(invocation.scenarioInput?.path ?? "")
        }
        if let path = scenario.source.staticHTMLPath,
           scenario.source.launchMode == "staticHTML",
           !manager.fileExists(atPath: path) {
            throw CLIError.missingFile(path)
        }
        if let path = scenario.source.projectPath {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CLIError.missingDirectory(path)
            }
        }
        for output in [invocation.screenshotOutput, invocation.videoOutput, invocation.reportOutput].compactMap({ $0 }) {
            if manager.fileExists(atPath: output.path), !invocation.overwrite {
                throw CLIError.outputExists(output.path)
            }
            try manager.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        if let directory = invocation.artifactDirectory {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            artifactPaths["checkpointDirectory"] = directory.path
        }
    }

    private func preparePreview() throws {
        let configuration = scenario.configuration
        preview = DevicePreviewView(profile: configuration.profile)
        preview.delegate = self
        preview.safeArea = configuration.safeArea.configuredPortrait
        preview.landscape = configuration.orientation == "landscape"
        preview.showSafeArea = configuration.safeArea.guideVisible
        preview.applySafeAreaToPage = configuration.safeArea.forcedIntoPageLayout
        if configuration.header.enabled {
            preview.headerHTML = configuration.header.html
            preview.headerHeight = CGFloat(configuration.header.heightCSSPixels)
            preview.headerBaseURL = configuration.header.baseURL.flatMap(URL.init(string:))
                ?? configuration.header.sourcePath
                    .map(URL.init(fileURLWithPath:))
                    .map { $0.deletingLastPathComponent() }
        }
        if configuration.footer.enabled {
            preview.footerHTML = configuration.footer.html
            preview.footerHeight = CGFloat(configuration.footer.heightCSSPixels)
            preview.footerBaseURL = configuration.footer.baseURL.flatMap(URL.init(string:))
                ?? configuration.footer.sourcePath
                    .map(URL.init(fileURLWithPath:))
                    .map { $0.deletingLastPathComponent() }
        }
        if let left = configuration.left, left.enabled {
            preview.leftHTML = left.html
            preview.leftWidth = CGFloat(left.reservedExtentCSSPixels)
            preview.leftBaseURL = left.baseURL.flatMap(URL.init(string:))
                ?? left.sourcePath
                    .map(URL.init(fileURLWithPath:))
                    .map { $0.deletingLastPathComponent() }
        }
        if let right = configuration.right, right.enabled {
            preview.rightHTML = right.html
            preview.rightWidth = CGFloat(right.reservedExtentCSSPixels)
            preview.rightBaseURL = right.baseURL.flatMap(URL.init(string:))
                ?? right.sourcePath
                    .map(URL.init(fileURLWithPath:))
                    .map { $0.deletingLastPathComponent() }
        }

        let size = preview.logicalSize
        let frame = CGRect(origin: .zero, size: size)
        preview.frame = frame
        preview.bounds = frame
        preview.autoresizingMask = [.width, .height]
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = preview
        if let visibleFrame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: visibleFrame.maxX - size.width, y: visibleFrame.minY))
        }
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        panel.orderFrontRegardless()
        window = panel
        preview.layoutSubtreeIfNeeded()
    }

    private func loadSource() throws {
        server.delegate = self
        let source = scenario.source
        if source.launchMode == "staticHTML", let path = source.staticHTMLPath {
            preview.loadLocalFile(URL(fileURLWithPath: path), resetSiteData: true)
            return
        }
        if let path = source.projectPath {
            let project = URL(fileURLWithPath: path, isDirectory: true)
            preview.prepareForLocalServerLaunch()
            if source.launchMode == "customCommand", let command = source.customCommand {
                try server.startCommand(folder: project, command: command)
            } else {
                try server.start(folder: project, script: source.npmScript ?? "dev")
            }
            return
        }
        guard let rawURL = source.finalURL ?? source.requestedURL,
              let url = PreviewNavigationPolicy.normalizedWebURL(from: rawURL) else {
            throw CLIError.invalidArgument("The scenario does not contain a replayable source.")
        }
        preview.loadResettingSiteData(url.absoluteString)
    }

    private func beginTimeout() {
        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure(CLIError.timeout(self?.invocation.timeout ?? 0)))
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + invocation.timeout, execute: work)
    }

    func previewDidStartLoading() {}

    func previewDidFinishLoading(title: String?, url: URL?) {
        guard let url, !pipelineStarted else { return }
        finalURL = url
        pipelineStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + invocation.delay) { [weak self] in
            self?.beginReplay()
        }
    }

    func previewDidFail(_ message: String) {
        finish(.failure(CLIError.navigation(message)))
    }

    func devServerStateChanged(_ state: DevServerState, url: URL?) {
        switch state {
        case .running:
            guard let url else { return }
            preview.loadLocalServer(replayURL(serverURL: url).absoluteString, resetSiteData: true)
        case .failed:
            finish(.failure(CLIError.serverFailed))
        default:
            break
        }
    }

    func devServerDidOutput(_ line: String, isError: Bool) {
        serverLog.append(["stream": isError ? "stderr" : "stdout", "message": line])
        if serverLog.count > 300 { serverLog.removeFirst(serverLog.count - 300) }
        ViewDeckCommand.writeError(line)
    }

    private func replayURL(serverURL: URL) -> URL {
        guard let raw = scenario.source.finalURL,
              let recorded = URL(string: raw),
              var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL
        }
        components.path = recorded.path
        components.query = recorded.query
        components.fragment = recorded.fragment
        return components.url ?? serverURL
    }

    private func beginReplay() {
        guard !finished else { return }
        if let videoURL = invocation.videoOutput {
            videoFinished = false
            let recorder = LivePreviewVideoRecorder(
                outputURL: videoURL,
                duration: nil,
                framesPerSecond: invocation.videoFPS,
                captureScale: invocation.videoScale,
                overwrite: invocation.overwrite
            )
            videoRecorder = recorder
            recorder.record(preview: preview) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.artifactPaths["video"] = videoURL.path
                case .failure(let error):
                    self.replayErrors.append(error.localizedDescription)
                }
                self.videoFinished = true
                self.finishReplayIfReady()
            }
        }

        let controller = QAPlaybackController(
            preview: preview,
            scenario: scenario,
            speed: invocation.playbackSpeed,
            smartTiming: invocation.smartPlayback,
            checkpointHandler: { [weak self] checkpoint, done in
                self?.captureCheckpoint(checkpoint, completion: done)
            },
            completion: { [weak self] summary in
                guard let self else { return }
                self.playbackSummary = summary
                self.replayErrors.append(contentsOf: summary.errorMessages)
                self.videoRecorder?.stop()
                self.finishReplayIfReady()
            }
        )
        playback = controller
        controller.start()
    }

    private func captureCheckpoint(_ checkpoint: QACheckpoint, completion: @escaping () -> Void) {
        guard let directory = invocation.artifactDirectory else {
            completion()
            return
        }
        let index = checkpointPaths.count + 1
        let output = directory.appendingPathComponent(
            "checkpoint-\(String(format: "%03d", index)).png"
        )
        if FileManager.default.fileExists(atPath: output.path), !invocation.overwrite {
            replayErrors.append("Checkpoint output exists: \(output.path)")
            completion()
            return
        }
        preview.captureScreenshot(scale: invocation.captureScale) { [weak self] result in
            guard let self else {
                completion()
                return
            }
            do {
                let image = try result.get()
                try CLIImage.pngData(image).write(to: output, options: .atomic)
                self.checkpointPaths.append(output.path)
            } catch {
                self.replayErrors.append(error.localizedDescription)
            }
            completion()
        }
    }

    private func finishReplayIfReady() {
        guard playbackSummary != nil, videoFinished, !finalizing, !finished else { return }
        finalizing = true
        captureFinalScreenshot()
    }

    private func captureFinalScreenshot() {
        guard let output = invocation.screenshotOutput else {
            inspectPage()
            return
        }
        preview.captureScreenshot(scale: invocation.captureScale) { [weak self] result in
            guard let self else { return }
            do {
                let image = try result.get()
                if self.invocation.overwrite, FileManager.default.fileExists(atPath: output.path) {
                    try FileManager.default.removeItem(at: output)
                }
                try CLIImage.pngData(image).write(to: output, options: .atomic)
                self.artifactPaths["screenshot"] = output.path
                self.inspectPage()
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func inspectPage() {
        preview.captureAudit { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(.failure(error))
            case .success(let audit):
                do {
                    let report = try self.makeReport(audit: audit)
                    self.finish(.success(report))
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func makeReport(audit: [String: Any]) throws -> [String: Any] {
        let summary = playbackSummary!
        let pageErrors = audit["pageErrors"] as? [Any] ?? []
        let auditIssues = audit["issues"] as? [Any] ?? []
        let policyFailure = (invocation.failOnPageError && !pageErrors.isEmpty)
            || (invocation.failOnIssues && !auditIssues.isEmpty)
        if !checkpointPaths.isEmpty { artifactPaths["checkpoints"] = checkpointPaths }
        if let reportURL = invocation.reportOutput { artifactPaths["report"] = reportURL.path }

        let configurationData = try JSONEncoder().encode(scenario.configuration)
        let configurationObject = try JSONSerialization.jsonObject(with: configurationData)
        let timingPlanData = try JSONEncoder().encode(summary.timing)
        let timingPlanObject = try JSONSerialization.jsonObject(with: timingPlanData)
        let playbackSpeedValue: Any
        if invocation.smartPlayback {
            playbackSpeedValue = "smart"
        } else if invocation.playbackSpeed == 0 {
            playbackSpeedValue = "maximum"
        } else {
            playbackSpeedValue = invocation.playbackSpeed
        }
        let report: [String: Any] = [
            "schemaVersion": 1,
            "ok": replayErrors.isEmpty && !policyFailure,
            "command": "qa replay",
            "scenario": [
                "id": scenario.id,
                "name": scenario.name,
                "path": invocation.scenarioInput?.path ?? "",
                "schemaVersion": scenario.schemaVersion
            ],
            "source": [
                "finalURL": finalURL?.absoluteString ?? "",
                "recordedFinalURL": scenario.source.finalURL ?? "",
                "project": scenario.source.projectPath ?? "",
                "launchMode": scenario.source.launchMode ?? ""
            ],
            "configuration": configurationObject,
            "playback": [
                "speed": playbackSpeedValue,
                "recordedDurationMilliseconds": scenario.timing.durationMilliseconds,
                "originalTimelineMilliseconds": summary.timing.originalDurationMilliseconds,
                "effectiveTimelineMilliseconds": summary.timing.effectiveDurationMilliseconds,
                "savedMilliseconds": summary.timing.savedMilliseconds,
                "elapsedMilliseconds": summary.elapsedMilliseconds,
                "eventCount": summary.eventCount,
                "checkpointCount": summary.checkpointCount
            ],
            "timingPlan": timingPlanObject,
            "errors": replayErrors,
            "audit": audit,
            "serverLog": serverLog,
            "artifacts": artifactPaths,
            "timing": [
                "startedAt": ISO8601DateFormatter().string(from: startedAt),
                "finishedAt": ISO8601DateFormatter().string(from: Date()),
                "durationMilliseconds": Int(Date().timeIntervalSince(startedAt) * 1_000)
            ]
        ]
        if let reportURL = invocation.reportOutput {
            if invocation.overwrite, FileManager.default.fileExists(atPath: reportURL.path) {
                try FileManager.default.removeItem(at: reportURL)
            }
            try CLIJSON.data(report, pretty: true).write(to: reportURL, options: .atomic)
        }
        return report
    }

    private func finish(_ result: Result<[String: Any], Error>) {
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        server.stop()
        window?.orderOut(nil)
        window = nil
        completion(result)
    }
}

private final class PreviewVideoRecorder {
    private let outputURL: URL
    private let duration: TimeInterval
    private let framesPerSecond: Int
    private let captureScale: CGFloat
    private let overwrite: Bool
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameIndex = 0
    private var recordStartedAt: Date?
    private var frameCount: Int {
        max(1, Int((duration * Double(framesPerSecond)).rounded()))
    }

    init(
        outputURL: URL,
        duration: TimeInterval,
        framesPerSecond: Int,
        captureScale: CGFloat,
        overwrite: Bool
    ) {
        self.outputURL = outputURL
        self.duration = duration
        self.framesPerSecond = framesPerSecond
        self.captureScale = captureScale
        self.overwrite = overwrite
    }

    func record(
        preview: DevicePreviewView,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if overwrite, FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        recordStartedAt = Date()
        scheduleNextFrame(preview: preview, completion: completion)
    }

    private func scheduleNextFrame(
        preview: DevicePreviewView,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let start = recordStartedAt ?? Date()
        let target = start.addingTimeInterval(Double(frameIndex) / Double(framesPerSecond))
        let delay = max(0, target.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.captureNextFrame(preview: preview, completion: completion)
        }
    }

    private func captureNextFrame(
        preview: DevicePreviewView,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        preview.captureScreenshot(scale: captureScale) { [weak self] result in
            guard let self else { return }
            do {
                let image = try result.get()
                if self.writer == nil {
                    try self.prepareWriter(for: image)
                }
                try self.append(image: image, at: self.frameIndex)
                self.frameIndex += 1
                if self.frameIndex >= self.frameCount {
                    self.finish(completion: completion)
                } else {
                    self.scheduleNextFrame(preview: preview, completion: completion)
                }
            } catch {
                self.writer?.cancelWriting()
                completion(.failure(error))
            }
        }
    }

    private func prepareWriter(for image: NSImage) throws {
        guard let representation = CLIImage.bestBitmap(in: image) else {
            throw CLIError.imageEncoding
        }
        let width = Self.even(representation.pixelsWide)
        let height = Self.even(representation.pixelsHigh)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitrate = min(24_000_000, max(2_000_000, width * height * 5))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )
        guard writer.canAdd(input) else { throw CLIError.videoEncoding("Cannot add the H.264 video input.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CLIError.videoEncoding("The MP4 writer could not start.")
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    private func append(image: NSImage, at index: Int) throws {
        guard let input, let adaptor, let pool = adaptor.pixelBufferPool else {
            throw CLIError.videoEncoding("The video pixel-buffer pool is unavailable.")
        }
        guard input.isReadyForMoreMediaData else {
            throw CLIError.videoEncoding("The H.264 encoder did not accept the next frame.")
        }
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw CLIError.videoEncoding("Could not allocate a video frame.")
        }
        try CLIImage.draw(image, into: buffer)
        let timestamp = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(framesPerSecond))
        guard adaptor.append(buffer, withPresentationTime: timestamp) else {
            throw writer?.error ?? CLIError.videoEncoding("Could not append a video frame.")
        }
    }

    private func finish(completion: @escaping (Result<Void, Error>) -> Void) {
        input?.markAsFinished()
        writer?.finishWriting { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.writer?.status == .completed {
                    completion(.success(()))
                } else {
                    completion(.failure(
                        self.writer?.error ?? CLIError.videoEncoding("The MP4 writer did not finish.")
                    ))
                }
            }
        }
    }

    private static func even(_ value: Int) -> Int {
        max(2, value.isMultiple(of: 2) ? value : value + 1)
    }
}

private enum CLIImage {
    static func bestBitmap(in image: NSImage) -> NSBitmapImageRep? {
        image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { lhs, rhs in
                lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
            }
    }

    static func pngData(_ image: NSImage) throws -> Data {
        guard let data = bestBitmap(in: image)?.representation(using: .png, properties: [:]) else {
            throw CLIError.imageEncoding
        }
        return data
    }

    static func draw(_ image: NSImage, into buffer: CVPixelBuffer) throws {
        guard let representation = bestBitmap(in: image),
              let source = representation.cgImage else {
            throw CLIError.imageEncoding
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw CLIError.videoEncoding("The video frame has no writable memory.")
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw CLIError.videoEncoding("Could not create the video drawing context.")
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

enum CLIPath {
    static func url(_ value: String, directory: Bool = false) -> URL {
        let expanded = NSString(string: value).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: directory).standardizedFileURL
        }
        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(expanded, isDirectory: directory)
        .standardizedFileURL
    }

    static func appending(route: String?, to url: URL) -> URL {
        guard let route, !route.isEmpty else { return url }
        if let absolute = URL(string: route), absolute.scheme != nil { return absolute }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let normalized = route.hasPrefix("/") ? route : "/\(route)"
        components?.path = normalized
        return components?.url ?? url
    }
}

private enum CLIJSON {
    static func data(_ object: Any, pretty: Bool) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CLIError.jsonEncoding
        }
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    static func removingInvalidNulls(_ value: [String: Any]) -> [String: Any] {
        value.compactMapValues { item in
            if let optional = unwrapOptional(item) { return optional }
            return nil
        }
    }

    private static func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first?.value
    }
}

private enum CLIError: LocalizedError {
    case invalidArgument(String)
    case unknownDevice(String)
    case missingFile(String)
    case missingDirectory(String)
    case outputExists(String)
    case navigation(String)
    case preparation(String)
    case timeout(TimeInterval)
    case serverFailed
    case imageEncoding
    case videoEncoding(String)
    case jsonEncoding

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message): return message
        case .unknownDevice(let id):
            return "Unknown device `\(id)`. Run `viewdeck devices list` to see valid IDs."
        case .missingFile(let path): return "File does not exist: \(path)"
        case .missingDirectory(let path): return "Directory does not exist: \(path)"
        case .outputExists(let path): return "Output already exists: \(path). Pass --overwrite to replace it."
        case .navigation(let message): return "Page navigation failed: \(message)"
        case .preparation(let message): return "Page preparation failed: \(message)"
        case .timeout(let seconds): return "Timed out after \(seconds) seconds."
        case .serverFailed: return "The local development server exited before the preview was ready."
        case .imageEncoding: return "ViewDeck could not encode the screenshot as PNG."
        case .videoEncoding(let message): return "ViewDeck could not encode the MP4: \(message)"
        case .jsonEncoding: return "ViewDeck could not encode the JSON report."
        }
    }
}

private enum CLIHelp {
    static let text = """
    ViewDeck CLI

    Render, inspect, and record websites with ViewDeck's native WKWebView device previews.

    USAGE
      viewdeck devices list [--json]
      viewdeck capabilities [--json]
      viewdeck capture <url> --output <image.png> [options]
      viewdeck inspect <url> [--report <report.json>] [options]
      viewdeck record <url> --output <video.mp4> [options]
      viewdeck qa replay <scenario.viewdeck.json> [options]
      viewdeck qa template <url> --output <scenario.viewdeck.json> [options]

    SOURCES
      <url>, --url <url>             Load an HTTP or HTTPS URL
      --file <index.html>            Load a local HTML file
      --project <folder>             Start a local project
      --npm-script <name>            npm script to run (default: dev)
      --command <command>            Custom command to run inside --project
      --path <route>                 Route to load after server discovery

    DEVICE AND LAYOUT
      --device <id>                  Device profile (default: iphone-17-pro-max)
      --orientation <value>          portrait or landscape
      --show-safe-area               Draw the safe-area guide
      --apply-safe-area              Force page content inside the safe area
      --header <file.html>           Add an HTML header layer
      --header-height <points>       Header height (default: 48)
      --footer <file.html>           Add an HTML footer layer
      --footer-height <points>       Footer height (default: 56)
      --left <file.html>             Add a landscape left rail layer
      --left-width <points>          Left rail width (default: 118)
      --right <file.html>            Add a landscape right rail layer
      --right-width <points>         Right rail width (default: 118)

    READINESS
      --wait-for <selector>          Wait for a CSS selector
      --wait-js <expression>         Wait until a JavaScript expression is truthy
      --prepare-js <script>          Run JavaScript once after readiness
      --delay <seconds>              Settle delay after readiness (default: 0.5)
      --timeout <seconds>            Overall timeout (default: 30)

    ARTIFACTS
      --output <path>                Main PNG, MP4, or QA scenario output
      --screenshot <image.png>       Also write a screenshot
      --video <video.mp4>            Also write a video
      --report <report.json>         Write the machine-readable audit report
      --scale <0.5...3>              Screenshot scale (default: device DPR)
      --video-scale <0.5...3>        Video capture scale (default: 1)
      --duration <seconds>           Video duration (default: 5)
      --fps <1...30>                 Video frames per second (default: 30)
      --overwrite                    Replace existing output files

    QA REPLAY
      --speed <factor|smart|max>     Replay timing policy (default: 1)
      --artifacts <folder>           Capture screenshots at recorded checkpoints
      --video <video.mp4>            Record the complete replay
      --screenshot <image.png>       Capture the final replay state
      --report <report.json>         Write replay results, audit, and artifacts

    QA TEMPLATE
      --output <scenario.json>       Write a valid AI-authoring scenario skeleton
      --name <name>                  Override the scenario name
      --device, layout, and source options are shared with capture

    OUTPUT AND POLICY
      --json                         Print the report as JSON
      --fail-on-page-error           Exit 1 when the page reports an uncaught error
      --fail-on-issues               Exit 1 when the layout audit finds an issue

    EXAMPLES
      viewdeck devices list --json
      viewdeck capture http://localhost:5173 --device iphone-17-pro-max --output page.png --report page.json
      viewdeck inspect --project . --npm-script dev --wait-for canvas --json
      viewdeck record --project . --npm-script dev --wait-for canvas --duration 6 --fps 12 --output game.mp4 --screenshot game.png --report game.json
      viewdeck qa template http://localhost:5173 --device iphone-17-pro-max --output gameplay.viewdeck.json
      viewdeck qa replay gameplay.viewdeck.json --speed smart --artifacts qa-results --video replay.mp4 --report replay.json
    """
}
