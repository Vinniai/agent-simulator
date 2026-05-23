import ArgumentParser

@main
struct AgentSim: AsyncParsableCommand {
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
            DoubleTapCommand.self,
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
            NotesCommand.self,
            DoctorCommand.self,
        ]
    )
}
