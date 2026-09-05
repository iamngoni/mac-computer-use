import MacComputerUseCore

switch macComputerUseLaunchMode(
    arguments: CommandLine.arguments,
    standardInputIsPipe: standardInputIsPipe()
) {
case .manager:
    MainActor.assumeIsolated { runMacComputerUseManager() }
case .mcp, .overlay:
    runMacComputerUseService()
}
