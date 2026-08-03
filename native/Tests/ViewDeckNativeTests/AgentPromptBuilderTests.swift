import XCTest
@testable import ViewDeckCore

final class AgentPromptBuilderTests: XCTestCase {
    func testInitialConfigurationPreservesClickedDeviceSetup() throws {
        let profile = try XCTUnwrap(BuiltinDevices.all.first(where: { $0.id == "iphone-16-pro" }))
        let setup = CustomDeviceSetup(
            id: profile.id,
            profile: profile,
            landscape: true,
            showSafeArea: true,
            applySafeAreaToPage: true,
            header: CustomDeviceLayerSelection(identifier: "header", extent: 64)
        )
        let header = ViewDeckAgentLayerConfiguration(
            name: "Test header",
            path: "/tmp/header.html",
            extent: "64",
            isSelected: true
        )

        let configuration = ViewDeckAgentPromptConfiguration(
            setup: setup,
            sourceKind: .project,
            sourceValue: "/tmp/game",
            layers: [.header: header],
            network: shapedNetwork
        )

        XCTAssertEqual(configuration.deviceID, "iphone-16-pro")
        XCTAssertEqual(configuration.orientation, .landscape)
        XCTAssertTrue(configuration.showSafeArea)
        XCTAssertTrue(configuration.applySafeArea)
        XCTAssertEqual(configuration.header, header)
        XCTAssertEqual(configuration.networkRTT, "420")
        XCTAssertEqual(configuration.networkSeed, "99")
    }

    func testCapturePromptIncludesSkillDeviceAndStructuredCLIOptions() throws {
        var configuration = try baseConfiguration()
        configuration.waitSelector = "canvas"
        configuration.waitJavaScript = "window.gameReady === true"
        configuration.prepareJavaScript = "window.testMode = true"
        configuration.captureScale = "2"
        configuration.screenshotOutput = "final.png"
        configuration.videoOutput = "capture.mp4"
        configuration.additionalCLIArguments = "--future-flag value"

        let prompt = ViewDeckAgentPromptBuilder.prompt(for: configuration)

        for expected in [
            "Use the `viewdeck-qa` skill",
            "--device", "'iphone-16-pro'",
            "--orientation", "landscape",
            "--wait-for", "'canvas'",
            "--wait-js", "'window.gameReady === true'",
            "--audio", "verify-silent",
            "--network-rtt-ms", "'420'",
            "--header-height", "--duration", "'5'",
            "--future-flag value",
            "$ARTIFACT_DIR/capture.png",
            "Run `capabilities --json` and `devices list --json`"
        ] {
            XCTAssertTrue(prompt.contains(expected), "Missing \(expected)")
        }
    }

    func testVisiblePreviewNeverRequestsSilentAudioVerification() throws {
        var configuration = try baseConfiguration()
        configuration.showPreview = true

        let command = ViewDeckAgentPromptBuilder.commandDraft(configuration)

        XCTAssertTrue(command.contains("--show-preview"))
        XCTAssertFalse(command.contains("--audio"))
        XCTAssertFalse(command.contains("verify-silent"))
    }

    func testScenarioPromptGeneratesTemplateAndReplayCommands() throws {
        var configuration = try baseConfiguration()
        configuration.workflow = .qaScenario
        configuration.scenarioName = "Gameplay smoke test"
        configuration.scenarioOutput = "gameplay.viewdeck.json"
        configuration.checkpointDirectory = "checkpoints"
        configuration.videoOutput = "replay.mp4"
        configuration.replaySpeed = "smart"

        let command = ViewDeckAgentPromptBuilder.commandDraft(configuration)

        for expected in [
            "qa", "template", "--orientation", "landscape",
            "$ARTIFACT_DIR/gameplay.viewdeck.json",
            "replay", "--speed", "'smart'", "--artifacts",
            "\"$ARTIFACT_DIR/checkpoints\"",
            "--video", "\"$ARTIFACT_DIR/replay.mp4\""
        ] {
            XCTAssertTrue(command.contains(expected), "Missing \(expected)")
        }
    }

    func testEmbeddedLayerWithoutFilePathProducesAnExplicitWarning() throws {
        var configuration = try baseConfiguration()
        configuration.left = ViewDeckAgentLayerConfiguration(
            name: "h5_left",
            path: "",
            extent: "118",
            isSelected: true
        )

        let prompt = ViewDeckAgentPromptBuilder.prompt(for: configuration)

        XCTAssertTrue(prompt.contains("embedded layer(s) without a CLI file path"))
        XCTAssertTrue(prompt.contains("left ‘h5_left’"))
        XCTAssertFalse(ViewDeckAgentPromptBuilder.commandDraft(configuration).contains("--left"))
    }

    private var shapedNetwork: NetworkShapingConfiguration {
        NetworkShapingConfiguration(
            enabled: true,
            roundTripTimeMilliseconds: 420,
            jitterMilliseconds: 35,
            downloadKilobitsPerSecond: 1_200,
            uploadKilobitsPerSecond: 320,
            offline: false,
            seed: 99
        )
    }

    private func baseConfiguration() throws -> ViewDeckAgentPromptConfiguration {
        let profile = try XCTUnwrap(BuiltinDevices.all.first(where: { $0.id == "iphone-16-pro" }))
        let setup = CustomDeviceSetup(
            id: profile.id,
            profile: profile,
            landscape: true,
            showSafeArea: true,
            applySafeAreaToPage: true
        )
        let header = ViewDeckAgentLayerConfiguration(
            name: "Header",
            path: "/tmp/header.html",
            extent: "64",
            isSelected: true
        )
        return ViewDeckAgentPromptConfiguration(
            setup: setup,
            sourceKind: .project,
            sourceValue: "/tmp/game",
            projectLaunch: .npmScript,
            launchValue: "dev",
            layers: [.header: header],
            network: shapedNetwork
        )
    }
}
