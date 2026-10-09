import Foundation

/// Hansel's entry point. The same binary is the app and, with `--mcp-stdio`, the small
/// relay assistants launch to reach it; the relay must not start the app's UI or
/// services, nor quit because the app is already running.
@main
enum HanselMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().contains(MCPStdioBridge.flag) {
            MCPStdioBridge.run()
        }
        TimeTrackerApp.main()
    }
}
