import Foundation
import XCTest
@testable import ViewDeckCore

final class QAScenarioTests: XCTestCase {
    func testToolbarDefaultsToRecordingWithoutVideo() {
        XCTAssertFalse(DeckToolbarModel().recordQAVideo)
    }

    func testKeyboardEventPreservesTimingAndEveryKeyboardField() throws {
        let event = try XCTUnwrap(QAInputEvent(
            message: [
                "id": "key-1",
                "type": "keydown",
                "atMilliseconds": 325.5,
                "pageURL": "http://localhost:5173/game",
                "viewport": ["width": 440, "height": 956],
                "keyboard": [
                    "key": "ArrowLeft",
                    "code": "ArrowLeft",
                    "location": 1,
                    "repeat": true,
                    "isComposing": false,
                    "keyCode": 37,
                    "charCode": 0,
                    "altKey": false,
                    "ctrlKey": true,
                    "metaKey": false,
                    "shiftKey": true
                ],
                "target": [
                    "selector": "canvas#game",
                    "tagName": "canvas",
                    "isCanvas": true,
                    "rectangle": ["x": 0, "y": 0, "width": 440, "height": 956]
                ]
            ],
            previousAt: 125.25
        ))

        XCTAssertEqual(event.type, "keydown")
        XCTAssertEqual(event.atMilliseconds, 325.5)
        XCTAssertEqual(event.intervalSincePreviousMilliseconds, 200.25)
        XCTAssertEqual(event.viewportCSS, QASize(width: 440, height: 956))
        XCTAssertEqual(event.keyboard?.key, "ArrowLeft")
        XCTAssertEqual(event.keyboard?.code, "ArrowLeft")
        XCTAssertEqual(event.keyboard?.location, 1)
        XCTAssertEqual(event.keyboard?.keyCode, 37)
        XCTAssertTrue(event.keyboard?.repeatKey == true)
        XCTAssertTrue(event.keyboard?.control == true)
        XCTAssertTrue(event.keyboard?.shift == true)
        XCTAssertTrue(event.target?.isCanvas == true)
    }

    func testPointerEventPreservesAbsoluteAndNormalizedCoordinates() throws {
        let event = try XCTUnwrap(QAInputEvent(
            message: [
                "type": "pointerup",
                "atMilliseconds": 780,
                "viewport": ["width": 400, "height": 800],
                "pointer": [
                    "clientX": 100,
                    "clientY": 600,
                    "normalizedX": 0.25,
                    "normalizedY": 0.75,
                    "pageX": 100,
                    "pageY": 600,
                    "pointerID": 7,
                    "pointerType": "touch",
                    "isPrimary": true,
                    "pressure": 0.5,
                    "width": 8,
                    "height": 9
                ]
            ],
            previousAt: 500
        ))

        XCTAssertEqual(event.intervalSincePreviousMilliseconds, 280)
        XCTAssertEqual(event.pointer?.clientX, 100)
        XCTAssertEqual(event.pointer?.clientY, 600)
        XCTAssertEqual(event.pointer?.normalizedX, 0.25)
        XCTAssertEqual(event.pointer?.normalizedY, 0.75)
        XCTAssertEqual(event.pointer?.pointerID, 7)
        XCTAssertEqual(event.pointer?.pointerType, "touch")
    }

    func testWaitEventPreservesSemanticConditions() throws {
        let event = try XCTUnwrap(QAInputEvent(
            message: [
                "id": "wait-ready",
                "type": "wait",
                "atMilliseconds": 1_000,
                "viewport": ["width": 440, "height": 956],
                "wait": [
                    "selector": "canvas.ready",
                    "javascript": "window.gameReady === true",
                    "delayMilliseconds": 125,
                    "timeoutMilliseconds": 8_000,
                    "pollIntervalMilliseconds": 50
                ]
            ],
            previousAt: 500
        ))

        XCTAssertEqual(event.wait?.selector, "canvas.ready")
        XCTAssertEqual(event.wait?.javascript, "window.gameReady === true")
        XCTAssertEqual(event.wait?.delayMilliseconds, 125)
        XCTAssertEqual(event.wait?.timeoutMilliseconds, 8_000)
        XCTAssertEqual(event.wait?.pollIntervalMilliseconds, 50)
    }

    func testSmartTimingCompressesIdleGapsAndPreservesAtomicActions() throws {
        func pointerEvent(_ type: String, id: String, at: Double) throws -> QAInputEvent {
            try XCTUnwrap(QAInputEvent(
                message: [
                    "id": id,
                    "type": type,
                    "atMilliseconds": at,
                    "viewport": ["width": 440, "height": 956],
                    "pointer": [
                        "clientX": 100,
                        "clientY": 200,
                        "normalizedX": 100.0 / 440,
                        "normalizedY": 200.0 / 956,
                        "pointerID": 1,
                        "pointerType": "mouse",
                        "button": 0,
                        "buttons": type == "pointerdown" ? 1 : 0,
                        "isPrimary": true
                    ]
                ],
                previousAt: 0
            ))
        }
        func keyEvent(_ type: String, id: String, at: Double) throws -> QAInputEvent {
            try XCTUnwrap(QAInputEvent(
                message: [
                    "id": id,
                    "type": type,
                    "atMilliseconds": at,
                    "viewport": ["width": 440, "height": 956],
                    "keyboard": ["key": "ArrowRight", "code": "ArrowRight"]
                ],
                previousAt: 0
            ))
        }
        let events = try [
            pointerEvent("pointerdown", id: "pointer-down", at: 100),
            pointerEvent("pointerup", id: "pointer-up", at: 2_100),
            keyEvent("keydown", id: "key-down", at: 10_000),
            keyEvent("keyup", id: "key-up", at: 12_000)
        ]
        let checkpoint = QACheckpoint(
            id: "checkpoint",
            name: "After input",
            atMilliseconds: 20_000,
            intervalSincePreviousInputMilliseconds: 8_000,
            screenshotPath: "/tmp/checkpoint.png",
            screenshotPixelSize: QASize(width: 440, height: 956),
            captureScale: 1
        )

        let plan = QAPlaybackTimingPlanner.make(
            events: events,
            checkpoints: [checkpoint],
            speed: 1,
            smart: true
        )

        XCTAssertEqual(plan.summary.mode, "smart")
        XCTAssertEqual(plan.summary.entries.map(\.effectiveAtMilliseconds), [
            100, 2_100, 2_350, 4_350, 4_600
        ])
        XCTAssertEqual(plan.summary.entries.map(\.adjustment), [
            "short-gap-preserved",
            "atomic-action-preserved",
            "idle-gap-capped",
            "atomic-action-preserved",
            "idle-gap-capped"
        ])
        XCTAssertEqual(plan.summary.originalDurationMilliseconds, 20_000)
        XCTAssertEqual(plan.summary.effectiveDurationMilliseconds, 4_600)
        XCTAssertEqual(plan.summary.savedMilliseconds, 15_400)
        XCTAssertEqual(plan.summary.entries.last?.kind, "checkpoint")
    }

    func testGlobalReplayTimingStillScalesEveryTimestamp() throws {
        let event = try XCTUnwrap(QAInputEvent(
            message: [
                "id": "scaled",
                "type": "keydown",
                "atMilliseconds": 2_000,
                "viewport": ["width": 440, "height": 956],
                "keyboard": ["key": "Enter", "code": "Enter"]
            ],
            previousAt: 0
        ))

        let plan = QAPlaybackTimingPlanner.make(
            events: [event],
            checkpoints: [],
            speed: 4,
            smart: false
        )

        XCTAssertEqual(plan.summary.mode, "4.0x")
        XCTAssertEqual(plan.summary.entries.first?.originalAtMilliseconds, 2_000)
        XCTAssertEqual(plan.summary.entries.first?.effectiveAtMilliseconds, 500)
        XCTAssertEqual(plan.summary.entries.first?.adjustment, "globally-scaled")
    }

    func testTemplateConfigurationMatchesNativePreviewGeometry() {
        let profile = BuiltinDevices.all[0]
        let header = QALayerConfiguration(
            kind: .header,
            html: "<header>Score</header>",
            height: 48,
            sourcePath: nil,
            baseURL: nil
        )
        let footer = QALayerConfiguration(
            kind: .footer,
            html: "<footer>Controls</footer>",
            height: 56,
            sourcePath: nil,
            baseURL: nil
        )
        let left = QALayerConfiguration(
            kind: .left,
            html: "<nav>Browse</nav>",
            height: 118,
            sourcePath: nil,
            baseURL: nil
        )
        let right = QALayerConfiguration(
            kind: .right,
            html: "<aside>Actions</aside>",
            height: 118,
            sourcePath: nil,
            baseURL: nil
        )
        let preview = DevicePreviewView(profile: profile)
        preview.landscape = true
        preview.showSafeArea = true
        preview.applySafeAreaToPage = true
        preview.headerHTML = header.html
        preview.headerHeight = 48
        preview.footerHTML = footer.html
        preview.footerHeight = 56
        preview.leftHTML = left.html
        preview.leftWidth = 118
        preview.rightHTML = right.html
        preview.rightWidth = 118

        let captured = QADeviceConfiguration.capture(
            preview: preview,
            header: header,
            footer: footer,
            left: left,
            right: right
        )
        let generated = QADeviceConfiguration.template(
            profile: profile,
            landscape: true,
            showSafeArea: true,
            applySafeAreaToPage: true,
            header: header,
            footer: footer,
            left: left,
            right: right
        )

        XCTAssertEqual(generated, captured)
        XCTAssertEqual(generated.resolution.pageContentCSS.width, 720)
        XCTAssertEqual(generated.left?.kind, .left)
        XCTAssertEqual(generated.left?.widthCSSPixels, 118)
        XCTAssertEqual(generated.right?.kind, .right)
        XCTAssertEqual(generated.right?.widthCSSPixels, 118)
    }

    func testDerivesClicksAndSwipesWithGestureIntervals() throws {
        func pointerEvent(
            _ type: String,
            id: String,
            at: Double,
            x: Double,
            y: Double
        ) throws -> QAInputEvent {
            try XCTUnwrap(QAInputEvent(
                message: [
                    "id": id,
                    "type": type,
                    "atMilliseconds": at,
                    "viewport": ["width": 400, "height": 800],
                    "pointer": [
                        "clientX": x,
                        "clientY": y,
                        "normalizedX": x / 400,
                        "normalizedY": y / 800,
                        "pointerID": 1,
                        "pointerType": "mouse",
                        "isPrimary": true
                    ]
                ],
                previousAt: 0
            ))
        }
        let events = try [
            pointerEvent("pointerdown", id: "d1", at: 100, x: 10, y: 20),
            pointerEvent("pointerup", id: "u1", at: 180, x: 12, y: 21),
            pointerEvent("pointerdown", id: "d2", at: 600, x: 30, y: 40),
            pointerEvent("pointermove", id: "m2", at: 700, x: 120, y: 42),
            pointerEvent("pointerup", id: "u2", at: 850, x: 210, y: 45)
        ]

        let gestures = QAGestureDeriver.derive(from: events)

        XCTAssertEqual(gestures.count, 2)
        XCTAssertEqual(gestures[0].type, "click")
        XCTAssertEqual(gestures[0].durationMilliseconds, 80)
        XCTAssertEqual(gestures[0].intervalSincePreviousGestureMilliseconds, 100)
        XCTAssertEqual(gestures[1].type, "swipe")
        XCTAssertEqual(gestures[1].direction, "right")
        XCTAssertEqual(gestures[1].durationMilliseconds, 250)
        XCTAssertEqual(gestures[1].intervalSincePreviousGestureMilliseconds, 500)
        XCTAssertEqual(gestures[1].samples.count, 3)
        XCTAssertEqual(gestures[1].sourceEventIDs, ["d2", "m2", "u2"])
    }

    func testLayerConfigurationEmbedsPortableHTMLAndFingerprint() {
        let layer = QALayerConfiguration(
            kind: .header,
            html: "<header>Score</header>",
            height: 48,
            sourcePath: "/tmp/header.html",
            baseURL: URL(fileURLWithPath: "/tmp"),
            identifier: "score-header",
            name: "Score header"
        )

        XCTAssertTrue(layer.enabled)
        XCTAssertEqual(layer.heightCSSPixels, 48)
        XCTAssertEqual(layer.html, "<header>Score</header>")
        XCTAssertEqual(layer.htmlSHA256?.count, 64)
        XCTAssertEqual(layer.sourcePath, "/tmp/header.html")
    }

    func testPlaybackCanBeStoppedBeforeScheduledInputRuns() throws {
        let event = try XCTUnwrap(QAInputEvent(
            message: [
                "id": "future-key",
                "type": "keydown",
                "atMilliseconds": 10_000,
                "viewport": ["width": 440, "height": 956],
                "keyboard": ["key": "ArrowLeft", "code": "ArrowLeft"]
            ],
            previousAt: 0
        ))
        let preview = DevicePreviewView(profile: BuiltinDevices.all[1])
        let emptyHeader = QALayerConfiguration(
            kind: .header,
            html: nil,
            height: 48,
            sourcePath: nil,
            baseURL: nil
        )
        let emptyFooter = QALayerConfiguration(
            kind: .footer,
            html: nil,
            height: 56,
            sourcePath: nil,
            baseURL: nil
        )
        let now = Date()
        let scenario = QAScenario(
            schemaVersion: 1,
            id: "cancel-test",
            name: "cancel-test",
            generator: QAGenerator(
                name: "ViewDeck",
                version: "test",
                operatingSystem: "macOS",
                locale: "en_US",
                timeZone: "UTC",
                renderer: "WKWebView"
            ),
            source: QASourceConfiguration(
                requestedURL: "http://localhost:5173",
                finalURL: "http://localhost:5173",
                pageTitle: "Test",
                projectPath: nil,
                launchMode: "url",
                npmScript: nil,
                customCommand: nil,
                staticHTMLPath: nil
            ),
            configuration: QADeviceConfiguration.capture(
                preview: preview,
                header: emptyHeader,
                footer: emptyFooter
            ),
            environmentAtStart: nil,
            environmentAtEnd: nil,
            auditAtEnd: nil,
            timing: QATiming(
                clock: "monotonic milliseconds from recording start",
                recordedAt: now,
                finishedAt: now.addingTimeInterval(10),
                durationMilliseconds: 10_000,
                eventCount: 1,
                gestureCount: 0,
                checkpointCount: 0
            ),
            events: [event],
            gestures: [],
            checkpoints: [],
            artifacts: [],
            notes: []
        )
        let completed = expectation(description: "Playback reports cancellation")
        var summary: QAPlaybackController.ResultSummary?
        let playback = QAPlaybackController(
            preview: preview,
            scenario: scenario,
            speed: 1,
            checkpointHandler: { _, done in done() },
            completion: {
                summary = $0
                completed.fulfill()
            }
        )

        playback.start()
        playback.cancel()
        wait(for: [completed], timeout: 1)

        XCTAssertTrue(summary?.wasCancelled == true)
        XCTAssertEqual(summary?.eventCount, 0)
        XCTAssertEqual(summary?.checkpointCount, 0)
    }

    func testScenarioRoundTripContainsCompleteDeviceAndSafeAreaConfiguration() throws {
        let profile = BuiltinDevices.all[1]
        let emptyHeader = QALayerConfiguration(
            kind: .header,
            html: nil,
            height: 48,
            sourcePath: nil,
            baseURL: nil
        )
        let footer = QALayerConfiguration(
            kind: .footer,
            html: "<footer>Controls</footer>",
            height: 56,
            sourcePath: "/tmp/footer.html",
            baseURL: URL(fileURLWithPath: "/tmp"),
            name: "Controls"
        )
        let configuration = QADeviceConfiguration(
            profile: profile,
            orientation: "landscape",
            resolution: QAResolutionConfiguration(
                profilePortraitCSS: QASize(width: 440, height: 956),
                orientedScreenCSS: QASize(width: 956, height: 440),
                pageContentCSS: QASize(width: 956, height: 384),
                devicePixelRatio: 3,
                orientedScreenPhysicalPixels: QASize(width: 2868, height: 1320),
                pageContentPhysicalPixels: QASize(width: 2868, height: 1152)
            ),
            safeArea: QASafeAreaConfiguration(
                configuredPortrait: profile.safeArea,
                orientedDevice: EdgeInsets(top: 0, right: 34, bottom: 0, left: 62),
                exposedToPage: EdgeInsets(top: 0, right: 34, bottom: 0, left: 62),
                guideVisible: true,
                forcedIntoPageLayout: false,
                implementation: "CSS env variables only"
            ),
            safari: QASafariConfiguration(
                enabled: false,
                simulatedBrowser: "none",
                renderingEngine: "Apple WebKit (WKWebView)",
                userAgent: profile.userAgent,
                topChromeCSSPixels: 0,
                bottomChromeCSSPixels: 0
            ),
            header: emptyHeader,
            footer: footer
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scenario = QAScenario(
            schemaVersion: 1,
            id: "scenario-1",
            name: "keyboard-game",
            generator: QAGenerator(
                name: "ViewDeck",
                version: "0.3.0",
                operatingSystem: "macOS",
                locale: "en_US",
                timeZone: "UTC",
                renderer: "WKWebView"
            ),
            source: QASourceConfiguration(
                requestedURL: "http://localhost:5173",
                finalURL: "http://localhost:5173/game",
                pageTitle: "Game",
                projectPath: "/tmp/game",
                launchMode: "npmScript",
                npmScript: "dev",
                customCommand: nil,
                staticHTMLPath: nil
            ),
            configuration: configuration,
            environmentAtStart: .object(["userAgent": .string(profile.userAgent)]),
            environmentAtEnd: nil,
            auditAtEnd: nil,
            timing: QATiming(
                clock: "monotonic milliseconds from recording start",
                recordedAt: now,
                finishedAt: now.addingTimeInterval(1),
                durationMilliseconds: 1000,
                eventCount: 0,
                gestureCount: 0,
                checkpointCount: 0
            ),
            events: [],
            gestures: [],
            checkpoints: [],
            artifacts: [],
            notes: []
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scenario.viewdeck.json")

        try QAScenarioFiles.save(scenario, to: url)
        let decoded = try QAScenarioFiles.load(url)

        XCTAssertEqual(decoded, scenario)
        XCTAssertEqual(decoded.configuration.profile.shell, profile.shell)
        XCTAssertEqual(decoded.configuration.profile.sensor, profile.sensor)
        XCTAssertEqual(decoded.configuration.safeArea.orientedDevice.right, 34)
        XCTAssertTrue(decoded.configuration.safeArea.guideVisible)
        XCTAssertFalse(decoded.configuration.safari.enabled)
        XCTAssertTrue(decoded.configuration.footer.enabled)
        XCTAssertEqual(decoded.configuration.footer.html, "<footer>Controls</footer>")
    }
}
