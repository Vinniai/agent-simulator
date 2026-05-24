import Testing
import ArgumentParser
@testable import AgentSim

/// Parses each subcommand from argv and asserts the @Option/@OptionGroup
/// wiring + CommandConfiguration metadata. `run()` itself talks to
/// CoreSimulators / stdin / signals, so it stays out of coverage by
/// design — these tests only pin the structure.
@Suite("CommandParsing")
struct CommandParsingTests {

    // MARK: - root

    @Test func `agent-sim root lists every subcommand`() {
        let cfg = AgentSim.configuration
        #expect(cfg.commandName == "agent-sim")
        let names = cfg.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == [
            "agent",
            "list", "boot", "shutdown", "input", "stream",
            "tap", "double-tap", "swipe", "pinch", "pan", "press",
            "key", "type",
            "chrome", "screenshot", "describe-ui", "logs", "serve",
            "orientation", "diag-digitizer-trackpad", "review-tasks",
            "notes",
            "doctor",
        ])
    }

    @Test func `notes command exposes send + listen subcommands`() {
        let names = NotesCommand.configuration.subcommands
            .map { $0.configuration.commandName }
        #expect(Set(names) == ["list", "add", "promote", "watch"])
    }

    @Test func `agent-sim root exposes version`() {
        #expect(AgentSim.configuration.version == agentSimVersion)
        #expect(!agentSimVersion.isEmpty)
    }

    @Test func `agent command exposes feedback-loop subcommands`() {
        let names = AgentCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == ["bootstrap", "status", "quality-gate"])
    }

    // MARK: - list

    @Test func `list parses --device-set`() throws {
        let cmd = try ListCommand.parse(["--device-set", "/tmp/set"])
        #expect(cmd.deviceSet == "/tmp/set")
        #expect(ListCommand.configuration.commandName == "list")
    }

    @Test func `list defaults device-set to nil`() throws {
        let cmd = try ListCommand.parse([])
        #expect(cmd.deviceSet == nil)
        #expect(cmd.json == false)
    }

    @Test func `list parses --json flag`() throws {
        let cmd = try ListCommand.parse(["--json"])
        #expect(cmd.json == true)
    }

    // MARK: - boot / shutdown share DeviceOption

    @Test func `boot requires --udid`() throws {
        let cmd = try BootCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.options.deviceSet == nil)
        #expect(BootCommand.configuration.commandName == "boot")
    }

    @Test func `boot rejects argv without --udid`() {
        #expect(throws: (any Error).self) {
            try BootCommand.parse([])
        }
    }

    @Test func `shutdown carries udid + device-set`() throws {
        let cmd = try ShutdownCommand.parse([
            "--udid", "XYZ", "--device-set", "/var/sims",
        ])
        #expect(cmd.options.udid == "XYZ")
        #expect(cmd.options.deviceSet == "/var/sims")
        #expect(ShutdownCommand.configuration.commandName == "shutdown")
    }

    // MARK: - input

    @Test func `input parses --udid`() throws {
        let cmd = try InputCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(InputCommand.configuration.commandName == "input")
    }

    // MARK: - orientation

    @Test func `orientation parses portrait`() throws {
        let cmd = try OrientationCommand.parse(["--udid", "U", "portrait"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.value == .portrait)
        #expect(OrientationCommand.configuration.commandName == "orientation")
    }

    @Test func `orientation parses landscape-left`() throws {
        let cmd = try OrientationCommand.parse(["--udid", "U", "landscape-left"])
        #expect(cmd.value == .landscapeLeft)
    }

    @Test func `orientation parses landscape-right`() throws {
        let cmd = try OrientationCommand.parse(["--udid", "U", "landscape-right"])
        #expect(cmd.value == .landscapeRight)
    }

    @Test func `orientation parses portrait-upside-down`() throws {
        let cmd = try OrientationCommand.parse(["--udid", "U", "portrait-upside-down"])
        #expect(cmd.value == .portraitUpsideDown)
    }

    @Test func `orientation rejects unknown values`() {
        #expect(throws: (any Error).self) {
            try OrientationCommand.parse(["--udid", "U", "sideways"])
        }
    }

    @Test func `orientation rejects argv without --udid`() {
        #expect(throws: (any Error).self) {
            try OrientationCommand.parse(["portrait"])
        }
    }

    // MARK: - review-tasks add-code-change

    @Test func `add-code-change parses single change flags`() throws {
        let cmd = try ReviewTasksCommand.AddCodeChange.parse([
            "task_42",
            "--path", "Sources/Save/SaveButton.swift",
            "--summary", "added validation",
            "--start-line", "42",
            "--end-line", "58",
            "--commit-sha", "abc123",
            "--branch", "main",
            "--language", "swift",
            "--actor", "claude-agent",
        ])
        #expect(cmd.id == "task_42")
        #expect(cmd.path == "Sources/Save/SaveButton.swift")
        #expect(cmd.summary == "added validation")
        #expect(cmd.startLine == 42)
        #expect(cmd.endLine == 58)
        #expect(cmd.commitSha == "abc123")
        #expect(cmd.branch == "main")
        #expect(cmd.language == "swift")
        #expect(cmd.actor == "claude-agent")
        #expect(ReviewTasksCommand.AddCodeChange.configuration.commandName == "add-code-change")
    }

    @Test func `add-code-change accepts --changes-file alone`() throws {
        let cmd = try ReviewTasksCommand.AddCodeChange.parse([
            "task_42",
            "--changes-file", "/tmp/changes.json",
        ])
        #expect(cmd.changesFile == "/tmp/changes.json")
        #expect(cmd.path == nil)
    }

    // MARK: - diag-digitizer-trackpad

    @Test func `diag-digitizer-trackpad parses --udid`() throws {
        let cmd = try DiagDigitizerTrackpadCommand.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(DiagDigitizerTrackpadCommand.configuration.commandName == "diag-digitizer-trackpad")
    }

    // MARK: - stream

    @Test func `stream defaults match StreamConfig.default`() throws {
        let cmd = try StreamCommand.parse(["--udid", "ABC"])
        #expect(cmd.format == "mjpeg")
        #expect(cmd.fps == 60)
        #expect(cmd.quality == 0.70)
        #expect(cmd.bitrate == StreamConfig.default.bitrateBps)
        #expect(cmd.scale == StreamConfig.default.scale)
        #expect(StreamCommand.configuration.commandName == "stream")
    }

    @Test func `stream accepts every tunable knob`() throws {
        let cmd = try StreamCommand.parse([
            "--udid", "ABC",
            "--format", "avcc",
            "--fps", "30",
            "--quality", "0.9",
            "--bitrate", "8000000",
            "--scale", "2",
        ])
        #expect(cmd.format == "avcc")
        #expect(cmd.fps == 30)
        #expect(cmd.quality == 0.9)
        #expect(cmd.bitrate == 8_000_000)
        #expect(cmd.scale == 2)
    }

    // MARK: - gesture commands

    @Test func `tap parses point + size + duration`() throws {
        let cmd = try TapCommand.parse([
            "--udid", "ABC",
            "--x", "10", "--y", "20",
            "--width", "390", "--height", "844",
            "--duration", "0.1",
        ])
        #expect(cmd.x == 10 && cmd.y == 20)
        #expect(cmd.width == 390 && cmd.height == 844)
        #expect(cmd.duration == 0.1)
        #expect(TapCommand.configuration.commandName == "tap")
    }

    @Test func `tap duration defaults to 0.05`() throws {
        let cmd = try TapCommand.parse([
            "--udid", "ABC",
            "--x", "1", "--y", "2",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.duration == 0.05)
    }

    @Test func `double-tap parses point + size + interval + duration`() throws {
        let cmd = try DoubleTapCommand.parse([
            "--udid", "ABC",
            "--x", "220", "--y", "480",
            "--width", "402", "--height", "874",
            "--interval", "0.12",
            "--duration", "0.05",
        ])
        #expect(cmd.x == 220 && cmd.y == 480)
        #expect(cmd.width == 402 && cmd.height == 874)
        #expect(cmd.interval == 0.12)
        #expect(cmd.duration == 0.05)
        #expect(DoubleTapCommand.configuration.commandName == "double-tap")
    }

    @Test func `double-tap interval and duration default to observed-working cadence`() throws {
        let cmd = try DoubleTapCommand.parse([
            "--udid", "ABC",
            "--x", "1", "--y", "2",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.interval == 0.05)
        #expect(cmd.duration == 0.08)
    }

    @Test func `swipe parses start + end + size`() throws {
        let cmd = try SwipeCommand.parse([
            "--udid", "ABC",
            "--start-x", "0", "--start-y", "0",
            "--end-x", "100", "--end-y", "200",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.startX == 0 && cmd.startY == 0)
        #expect(cmd.endX == 100 && cmd.endY == 200)
        #expect(cmd.duration == 0.25)
        #expect(SwipeCommand.configuration.commandName == "swipe")
    }

    @Test func `pinch parses centre + spread`() throws {
        let cmd = try PinchCommand.parse([
            "--udid", "ABC",
            "--cx", "100", "--cy", "200",
            "--start-spread", "50", "--end-spread", "150",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.cx == 100 && cmd.cy == 200)
        #expect(cmd.startSpread == 50 && cmd.endSpread == 150)
        #expect(cmd.duration == 0.6)
        #expect(PinchCommand.configuration.commandName == "pinch")
    }

    @Test func `pan parses two contacts + delta`() throws {
        let cmd = try PanCommand.parse([
            "--udid", "ABC",
            "--x1", "10", "--y1", "20",
            "--x2", "30", "--y2", "40",
            "--dx", "5", "--dy=-5",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.x1 == 10 && cmd.y1 == 20)
        #expect(cmd.x2 == 30 && cmd.y2 == 40)
        #expect(cmd.dx == 5 && cmd.dy == -5)
        #expect(cmd.duration == 0.5)
        #expect(PanCommand.configuration.commandName == "pan")
    }

    @Test func `press parses --button`() throws {
        let cmd = try PressCommand.parse(["--udid", "ABC", "--button", "home"])
        #expect(cmd.button == "home")
        #expect(PressCommand.configuration.commandName == "press")
    }

    // MARK: - screenshot

    @Test func `screenshot defaults match snapshot helper`() throws {
        let cmd = try ScreenshotCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.output == nil)
        #expect(cmd.quality == 0.85)
        #expect(cmd.scale == 1)
        #expect(ScreenshotCommand.configuration.commandName == "screenshot")
    }

    @Test func `screenshot accepts --output --quality --scale`() throws {
        let cmd = try ScreenshotCommand.parse([
            "--udid", "ABC",
            "--output", "/tmp/x.jpg",
            "--quality", "0.5",
            "--scale", "2",
        ])
        #expect(cmd.output == "/tmp/x.jpg")
        #expect(cmd.quality == 0.5)
        #expect(cmd.scale == 2)
    }

    // MARK: - describe-ui

    @Test func `describe-ui requires --udid and defaults to full tree`() throws {
        let cmd = try DescribeUICommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.x == nil && cmd.y == nil)
        #expect(cmd.output == nil)
        #expect(DescribeUICommand.configuration.commandName == "describe-ui")
    }

    @Test func `describe-ui accepts --x --y --output`() throws {
        let cmd = try DescribeUICommand.parse([
            "--udid", "ABC",
            "--x", "120", "--y", "400",
            "--output", "/tmp/tree.json",
        ])
        #expect(cmd.x == 120 && cmd.y == 400)
        #expect(cmd.output == "/tmp/tree.json")
    }

    // MARK: - logs

    @Test func `logs requires --udid and defaults level + style`() throws {
        let cmd = try LogsCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.level == "info")
        #expect(cmd.style == "default")
        #expect(cmd.predicate == nil)
        #expect(cmd.bundleId == nil)
        #expect(LogsCommand.configuration.commandName == "logs")
    }

    @Test func `logs accepts --level --style --predicate --bundle-id`() throws {
        let cmd = try LogsCommand.parse([
            "--udid", "ABC",
            "--level", "debug",
            "--style", "json",
            "--predicate", #"subsystem == "com.apple.UIKit""#,
            "--bundle-id", "com.example.app",
        ])
        #expect(cmd.level == "debug")
        #expect(cmd.style == "json")
        #expect(cmd.predicate == #"subsystem == "com.apple.UIKit""#)
        #expect(cmd.bundleId == "com.example.app")
    }

    // MARK: - serve

    @Test func `serve defaults bind to 127.0.0.1:8421`() throws {
        let cmd = try ServeCommand.parse([])
        #expect(cmd.host == "127.0.0.1")
        #expect(cmd.port == 8421)
        #expect(cmd.deviceSet == nil)
        #expect(cmd.trustedHost == [])
        #expect(ServeCommand.configuration.commandName == "serve")
    }

    @Test func `serve overrides host + port + device-set`() throws {
        let cmd = try ServeCommand.parse([
            "--host", "0.0.0.0",
            "--port", "9000",
            "--device-set", "/tmp/sims",
        ])
        #expect(cmd.host == "0.0.0.0")
        #expect(cmd.port == 9000)
        #expect(cmd.deviceSet == "/tmp/sims")
    }

    @Test func `serve --trusted-host is repeatable for a Tailscale bind`() throws {
        let cmd = try ServeCommand.parse([
            "--host", "0.0.0.0",
            "--trusted-host", "mac.tailnet.ts.net",
            "--trusted-host", "100.101.102.103",
        ])
        #expect(cmd.trustedHost == ["mac.tailnet.ts.net", "100.101.102.103"])
    }

    // MARK: - review-tasks

    @Test func `review-tasks exposes agent queue subcommands`() {
        let names = ReviewTasksCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == ["list", "next", "show", "claim", "event", "result", "verify", "add-code-change", "bulk-create", "watch"])
    }

    @Test func `review-tasks next parses agent id`() throws {
        let cmd = try ReviewTasksCommand.Next.parse(["--agent-id", "agent-a"])
        #expect(cmd.agentId == "agent-a")
    }

    @Test func `review-tasks next accepts --actor as alias for --agent-id`() throws {
        let cmd = try ReviewTasksCommand.Next.parse(["--actor", "agent-a"])
        #expect(cmd.agentId == "agent-a")
    }

    @Test func `review-tasks claim accepts --actor as alias for --agent-id`() throws {
        let cmd = try ReviewTasksCommand.Claim.parse(["task-1", "--actor", "agent-a"])
        #expect(cmd.id == "task-1")
        #expect(cmd.agentId == "agent-a")
    }

    @Test func `review-tasks event parses streaming payload options`() throws {
        let cmd = try ReviewTasksCommand.Event.parse([
            "task-1",
            "--type", "capture",
            "--actor", "agent-a",
            "--message", "Captured screenshot",
            "--metadata-json", #"{"snapshotId":"snap-1"}"#,
        ])
        #expect(cmd.id == "task-1")
        #expect(cmd.type == "capture")
        #expect(cmd.actor == "agent-a")
        #expect(cmd.message == "Captured screenshot")
        #expect(cmd.metadataJSON == #"{"snapshotId":"snap-1"}"#)
    }

    @Test func `review-tasks result parses status and summary`() throws {
        let cmd = try ReviewTasksCommand.Result.parse([
            "task-1",
            "--status", "readyForVerify",
            "--actor", "agent-a",
            "--summary", "Implemented change",
            "--verification-snapshot-id", "snap-2",
        ])
        #expect(cmd.id == "task-1")
        #expect(cmd.status == "readyForVerify")
        #expect(cmd.actor == "agent-a")
        #expect(cmd.summary == "Implemented change")
        #expect(cmd.verificationSnapshotId == "snap-2")
    }

    @Test func `review-tasks watch parses poll filters`() throws {
        let cmd = try ReviewTasksCommand.Watch.parse([
            "--session-id", "review-1",
            "--status", "open",
            "--interval", "0.25",
            "--once",
        ])
        #expect(cmd.sessionId == "review-1")
        #expect(cmd.status == "open")
        #expect(cmd.interval == 0.25)
        #expect(cmd.once == true)
    }

    // MARK: - review-tasks bulk-create

    @Test func `review-tasks bulk-create parses session and file flags`() throws {
        let cmd = try ReviewTasksCommand.BulkCreate.parse([
            "--session-id", "review-bulk",
            "--file", "/tmp/tasks.json",
            "--assignee", "agent-import",
            "--priority", "high",
        ])
        #expect(cmd.sessionId == "review-bulk")
        #expect(cmd.file == "/tmp/tasks.json")
        #expect(cmd.assignee == "agent-import")
        #expect(cmd.priority == "high")
        #expect(cmd.title == nil)
        #expect(cmd.instructions == nil)
    }

    @Test func `review-tasks bulk-create accepts stdin via -`() throws {
        let cmd = try ReviewTasksCommand.BulkCreate.parse([
            "--session-id", "review-bulk",
            "--file", "-",
        ])
        #expect(cmd.file == "-")
    }

    // MARK: - doctor

    @Test func `doctor defaults to localhost on 8421 with text output`() throws {
        let cmd = try DoctorCommand.parse([])
        #expect(cmd.base == "http://127.0.0.1:8421")
        #expect(cmd.timeout == 2.0)
        #expect(cmd.json == false)
    }

    @Test func `doctor --json flag and custom base override defaults`() throws {
        let cmd = try DoctorCommand.parse([
            "--base", "http://127.0.0.1:9001",
            "--timeout", "0.5",
            "--json",
        ])
        #expect(cmd.base == "http://127.0.0.1:9001")
        #expect(cmd.timeout == 0.5)
        #expect(cmd.json == true)
    }
}
