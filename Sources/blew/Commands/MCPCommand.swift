#if MCP_ENABLED
import ArgumentParser
import Foundation

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Start MCP server for AI agent integration"
    )

    mutating func run() async throws {
        let server = BlewMCPServer(globals: GlobalOptions.current)
        try await server.start()
    }
}
#endif
