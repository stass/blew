import Foundation

/// Buffers all rendered output for programmatic retrieval (used by MCP server).
/// Streaming commands that call `render()` / `renderLive()` during execution
/// have their output captured here instead of written to stdout/stderr.
final class CollectingRenderer: OutputRenderer {
    private(set) var collected: [CommandOutput] = []
    private(set) var errors: [String] = []
    private(set) var infos: [String] = []
    private(set) var debugs: [String] = []

    func render(_ output: CommandOutput) { collected.append(output) }
    func renderError(_ message: String) { errors.append(message) }
    func renderInfo(_ message: String) { infos.append(message) }
    func renderDebug(_ message: String) { debugs.append(message) }
    func renderLive(_ text: String) { /* no-op in MCP mode */ }

    func reset() {
        collected.removeAll()
        errors.removeAll()
        infos.removeAll()
        debugs.removeAll()
    }
}
