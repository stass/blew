import Foundation

/// Discards all rendered output. Used by the MCP server, where stdout carries
/// the JSON-RPC transport and must never receive command output.
final class NullRenderer: OutputRenderer {
    func render(_ output: CommandOutput) {}
    func renderError(_ message: String) {}
    func renderInfo(_ message: String) {}
    func renderDebug(_ message: String) {}
    func renderLive(_ text: String) {}
}
