import ArgumentParser

@main
struct Baguette: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-sim",
        abstract: "Agent-driven iOS simulator control, capture, markup, and review",
        version: agentSimVersion,
        subcommands: [
            AgentCommand.self,
            ListCommand.self,
            BootCommand.self,
            ShutdownCommand.self,
            InputCommand.self,
            StreamCommand.self,
            TapCommand.self,
            SwipeCommand.self,
            PinchCommand.self,
            PanCommand.self,
            PressCommand.self,
            KeyCommand.self,
            TypeCommand.self,
            ChromeCommand.self,
            ScreenshotCommand.self,
            DescribeUICommand.self,
            LogsCommand.self,
            ServeCommand.self,
            OrientationCommand.self,
            DiagDigitizerTrackpadCommand.self,
            ReviewTasksCommand.self,
            DoctorCommand.self,
        ]
    )
}
