import Foundation

/// Config snippets that register lautli's read-only MCP server with an AI app.
/// Built from the current install location every time, so copying again fixes a moved app.
struct McpConnect {
    let paths: AppPaths

    var python: String { paths.python.path }
    var script: String { paths.workerSource.appending(path: "worker/lautli_worker/mcp_server.py").path }
    var isReady: Bool { FileManager.default.isExecutableFile(atPath: python) }

    var claudeCodeCommand: String { "claude mcp add --scope user lautli -- \(shellQuoted(python)) \(shellQuoted(script))" }

    var codexConfig: String {
        "[mcp_servers.lautli]\ncommand = \(quoted(python))\nargs = [\(quoted(script))]\n"
    }

    /// Claude Desktop and Cursor share this `mcpServers` shape.
    var jsonConfig: String {
        let server: [String: Any] = ["command": python, "args": [script]]
        let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": ["lautli": server]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func shellQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A JSON string literal is also a valid TOML basic string, as long as slashes stay unescaped (`\/` is not a TOML escape).
    private func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
