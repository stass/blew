import Foundation

protocol OutputRenderer {
    func render(_ output: CommandOutput)
    func renderError(_ message: String)
    func renderInfo(_ message: String)
    func renderDebug(_ message: String)
    func renderResult(_ result: CommandResult)
    func renderLive(_ text: String)
}

extension OutputRenderer {
    func renderResult(_ result: CommandResult) {
        for msg in result.debugs {
            renderDebug(msg)
        }
        for msg in result.infos {
            renderInfo(msg)
        }
        for msg in result.errors {
            renderError(msg)
        }
        for item in result.output {
            render(item)
        }
    }
}

func makeRenderer(format: OutputFormat, verbosity: Int) -> OutputRenderer {
    switch format {
    case .text:
        return TextRenderer(verbosity: verbosity)
    case .kv:
        return KVRenderer(verbosity: verbosity)
    }
}
